--[[
  Pension → Profile Builder — dual-write fork.

  Wraps the primary tax_form_items write path for
  income_type='pension_payments' and mirrors the row into the unified
  Profile Builder store (user_profile_answers with aggregated
  answer_json arrays) so the shadow engine stays current during the
  Phase 2 migration window.

  Gated by IncomeEngine.dual_write_enabled("pension_payments") — off
  by default, turned on per env via the INCOME_ENGINE_PENSION_PAYMENTS_DUAL_WRITE
  env var (see docs/PROFILE_BUILDER_UNIFICATION_PLAN.md §4 in the
  diy-tax-return-uk repo, and lapis/helper/income-engine.lua here).

  Shape differs from salary fork in one important way: pension is a
  MANY-rows-per-bucket model (many payments per section per year).
  Every mutation therefore doesn't just upsert its own row — it
  RE-AGGREGATES the whole bucket for that (user, year, section) and
  upserts the single user_profile_answers row that holds the JSON
  array. This keeps the shadow in exact lock-step with tax_form_items
  regardless of whether the mutation was a create, update, or delete.

  Delete-to-empty: if the last row in a bucket goes, we delete the
  answer row rather than storing `[]` — matches how the frontend's
  ContextSections treats missing vs. empty (missing = "no payments
  entered", empty array = "explicit empty" which we don't need).

  Same design rules as salary fork:

    1. NEVER breaks the primary write. Every entry point pcalls the
       DB work.
    2. Section → question_key map is DUPLICATED from the backfill
       (pension-profile-builder-backfill.lua) on purpose — routes vs
       migrations run in different contexts, no shared code, keep in
       sync by hand.
    3. ON CONFLICT DO UPDATE (year-scoped partial unique index) —
       the user just wrote a new value; the shadow MUST reflect it.

  Public API:

      PensionFork.on_change(user_id, tax_year, section_key)

  Every entry point is safe to call unconditionally — the flag check
  is inside the helper. Callers pass the identifying triple; the fork
  reads current tax_form_items state itself so create / update /
  delete all funnel through the same code path.
]]

local db = require("lapis.db")
local cjson = require("cjson")
local IncomeEngine = require("helper.income-engine")

local M = {}

-- Same map as pension-profile-builder-backfill.lua's SECTION_MAP.
-- Keep aligned by hand.
local SECTION_MAP = {
    pp_registered_schemes = { question_key = "pp_registered_payments", includes_flags = true },
    pp_employer_schemes   = { question_key = "pp_employer_payments",   includes_flags = false },
    pp_overseas_schemes   = { question_key = "pp_overseas_payments",   includes_flags = false },
}

local function parse_extra(raw)
    if raw == nil or raw == cjson.null or raw == "" then return {} end
    if type(raw) ~= "string" then return {} end
    local ok, parsed = pcall(cjson.decode, raw)
    if not ok or type(parsed) ~= "table" then return {} end
    return parsed
end

local function log_mismatch(op, user_id, section, err)
    ngx.log(ngx.ERR, string.format(
        "[PensionFork] INCOME_ENGINE_DUAL_WRITE_MISMATCH op=%s user=%s section=%s err=%s",
        op, tostring(user_id), tostring(section), tostring(err)
    ))
end

-- Rebuild the aggregate for one bucket. Reads every non-archived
-- tax_form_items row for (user, year, section), builds the JSON array
-- in creation order, and upserts (or deletes) the answer row.
local function rebuild_bucket(user_id, tax_year, section_key)
    local mapping = SECTION_MAP[section_key]
    if not mapping then return false, "unknown section_key: " .. tostring(section_key) end

    local qrows = db.query(
        "SELECT id FROM profile_questions WHERE question_key = ? LIMIT 1",
        mapping.question_key
    )
    if not qrows or #qrows == 0 then
        return false, "question " .. mapping.question_key .. " not seeded yet"
    end
    local qid = qrows[1].id

    local urows = db.query("SELECT uuid FROM users WHERE id = ? LIMIT 1", user_id)
    if not urows or #urows == 0 then return false, "user not found" end
    local user_uuid = urows[1].uuid

    local items = db.query([[
        SELECT description, amount, extra_json, namespace_id
        FROM tax_form_items
        WHERE user_id = ? AND income_type_key = 'pension_payments'
          AND section_key = ? AND tax_year = ? AND is_archived = false
        ORDER BY created_at
    ]], user_id, section_key, tax_year) or {}

    -- Empty bucket → drop the shadow answer row entirely (matches the
    -- backfill's absent-key convention, avoids leaving an empty [] in
    -- the JSON store the frontend would still render as "0 payments
    -- explicitly").
    if #items == 0 then
        db.query([[
            DELETE FROM user_profile_answers
            WHERE user_id = ? AND question_id = ? AND tax_year = ?
              AND entity_uuid IS NULL
        ]], user_id, qid, tax_year)
        return true
    end

    -- Namespace: take it from the first row. All rows in a bucket
    -- belong to the same user and were written with the same
    -- namespace context — mixed values would indicate corruption
    -- elsewhere.
    local namespace_id = items[1].namespace_id

    local rows = {}
    for _, it in ipairs(items) do
        local row_obj = {
            description = it.description or "",
            amount = tonumber(it.amount) or 0,
        }
        if mapping.includes_flags then
            local extra = parse_extra(it.extra_json)
            row_obj.relief_at_source = extra.relief_at_source == true
            row_obj.one_off = extra.one_off == true
        end
        rows[#rows + 1] = row_obj
    end
    local json_str = cjson.encode(rows)

    -- Same ON CONFLICT shape as the backfill — inferred against the
    -- year-scoped partial unique index idx_upa_user_question_year
    -- (WHERE entity_uuid IS NULL AND tax_year IS NOT NULL). Answer
    -- column is TEXT, no jsonb cast.
    db.query([[
        INSERT INTO user_profile_answers
            (uuid, user_id, user_uuid, namespace_id, question_id,
             entity_uuid, tax_year, answer_json,
             is_draft, answered_at, updated_at)
        VALUES (gen_random_uuid()::text, ?, ?, ?, ?,
                NULL, ?, ?,
                false, NOW(), NOW())
        ON CONFLICT (user_id, question_id, tax_year)
        WHERE entity_uuid IS NULL AND tax_year IS NOT NULL
        DO UPDATE SET
            answer_json = EXCLUDED.answer_json,
            updated_at = NOW()
    ]], user_id, user_uuid, namespace_id or db.NULL, qid,
        tax_year, json_str)

    return true
end

-- Public entry point -------------------------------------------------
--
-- Called after any successful mutation on tax_form_items for a
-- pension_payments row. Because the shadow is an AGGREGATE per
-- (user, year, section), every create / update / delete of any row
-- in a bucket produces the same rebuild — no need for per-op
-- variants.
--
-- Safe to call unconditionally — the income_type_key + flag checks
-- run inside.
function M.on_change(user_id, tax_year, section_key)
    if not IncomeEngine.dual_write_enabled("pension_payments") then return end
    if not user_id or not tax_year or not section_key then return end
    local ok, err = pcall(rebuild_bucket, user_id, tax_year, section_key)
    if not ok then log_mismatch("change", user_id, section_key, err) end
end

return M
