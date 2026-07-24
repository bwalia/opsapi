--[[
  Pension Payments — Phase 2 backfill.

  Copies every existing `tax_form_items WHERE income_type_key='pension_payments'`
  row into the unified Profile Builder store:

    N tax_form_items rows for a given (user, tax_year, section_key)
      → ONE user_profile_answers row with question_id = the section's
        repeating_group question and answer_json = JSON array of the
        row objects the user entered.

  Aggregation vs. Phase 1 (salary):
    - Salary was one-record-per-entity: each tax_form_records row
      became one user_profile_entities row and many user_profile_answers.
    - Pension is many-rows-per-year-per-section: N tax_form_items rows
      collapse into ONE user_profile_answers.answer_json array. There
      are no entities to create — the answer is scoped by (user,
      question_id, tax_year), matching the seed's answer_scope='year'.

  The source rows are LEFT IN PLACE. Retirement is Phase 3's job.

  Idempotency
    - answer_scope='year' answers use the (user_id, question_id,
      tax_year) partial unique index. ON CONFLICT DO UPDATE overwrites
      answer_json — a re-run always rebuilds the full array from
      current tax_form_items state. This is different from the salary
      backfill's ON CONFLICT DO NOTHING because a partial-then-full
      re-run needs the FULL aggregated array, not the first-write's
      partial one.

  Reversibility
    - Rebuilds from tax_form_items (still authoritative) on every run,
      so rolling back is: unset the flag, ignore user_profile_answers
      for pension_payments question_keys. Phase 3 will actually delete
      those answers.

  Only executed when PROJECT_CODE includes 'tax_copilot'.
]]

local db = require("lapis.db")
local cjson = require("cjson")

-- Map: tax_form_items.section_key → { question_key, includes_flags }
-- Only the registered-schemes section carries relief_at_source /
-- one_off flags — employer + overseas rows store just description +
-- amount. Emitting the flags on rows that never had them would leave
-- garbage `false` values in the JSON array; skip.
local SECTION_MAP = {
    pp_registered_schemes = { question_key = "pp_registered_payments", includes_flags = true },
    pp_employer_schemes   = { question_key = "pp_employer_payments",   includes_flags = false },
    pp_overseas_schemes   = { question_key = "pp_overseas_payments",   includes_flags = false },
}

-- Parse a tax_form_items.extra_json blob (may be nil, "", or a JSON
-- object). Falls through to an empty table on any decode error so a
-- corrupted extra doesn't fail the whole row.
local function parse_extra(raw)
    if raw == nil or raw == cjson.null or raw == "" then return {} end
    if type(raw) ~= "string" then return {} end
    local ok, parsed = pcall(cjson.decode, raw)
    if not ok or type(parsed) ~= "table" then return {} end
    return parsed
end

-- Backfill body extracted to module scope so a re-run step ([2]) can
-- call it. Idempotent: ON CONFLICT DO UPDATE on the answer row so
-- every run leaves user_profile_answers.answer_json in exact sync
-- with the current tax_form_items state for that (user, year,
-- section).
local function backfill_pension()
    -- 1. Question-id lookup, batched — one SELECT for all 3 keys.
    local keys = {}
    for _, m in pairs(SECTION_MAP) do keys[#keys + 1] = m.question_key end
    local q_rows = db.query(
        "SELECT id, question_key FROM profile_questions WHERE question_key = ANY(?)",
        db.array(keys)
    ) or {}
    if #q_rows < #keys then
        print("[Pension backfill] Skipping — catalog seed hasn't fully applied yet ("
            .. #q_rows .. "/" .. #keys .. " questions present). Re-run 764 catches up.")
        return
    end
    local q_id_by_key = {}
    for _, r in ipairs(q_rows) do q_id_by_key[r.question_key] = r.id end

    -- 2. Users → uuid, batched. answer_scope='year' rows still need
    -- both user_id and user_uuid populated (schema convention across
    -- all profile answers).
    local users_needed = {}
    local user_rows = db.query([[
        SELECT DISTINCT user_id FROM tax_form_items
        WHERE income_type_key = 'pension_payments' AND is_archived = false
    ]]) or {}
    for _, u in ipairs(user_rows) do users_needed[#users_needed + 1] = u.user_id end
    if #users_needed == 0 then
        print("[Pension backfill] Nothing to backfill (0 pension_payments items).")
        return
    end
    local uuid_rows = db.query(
        "SELECT id, uuid FROM users WHERE id = ANY(?)",
        db.array(users_needed)
    ) or {}
    local user_uuid_by_id = {}
    for _, r in ipairs(uuid_rows) do user_uuid_by_id[r.id] = r.uuid end

    -- 3. Pull every non-archived pension item, then bucket by
    -- (user_id, tax_year, section_key). Each bucket becomes one
    -- user_profile_answers row.
    local items = db.query([[
        SELECT user_id, namespace_id, tax_year, section_key, description,
               amount, extra_json, created_at
        FROM tax_form_items
        WHERE income_type_key = 'pension_payments' AND is_archived = false
        ORDER BY user_id, tax_year, section_key, created_at
    ]]) or {}

    local buckets = {}
    local order_seen = {}
    for _, it in ipairs(items) do
        local mapping = SECTION_MAP[it.section_key]
        if mapping then
            local key = it.user_id .. "|" .. it.tax_year .. "|" .. it.section_key
            if not buckets[key] then
                buckets[key] = {
                    user_id = it.user_id,
                    namespace_id = it.namespace_id,
                    tax_year = it.tax_year,
                    section_key = it.section_key,
                    mapping = mapping,
                    rows = {},
                }
                order_seen[#order_seen + 1] = key
            end
            local row_obj = {
                description = it.description or "",
                amount = tonumber(it.amount) or 0,
            }
            if mapping.includes_flags then
                local extra = parse_extra(it.extra_json)
                row_obj.relief_at_source = extra.relief_at_source == true
                row_obj.one_off = extra.one_off == true
            end
            table.insert(buckets[key].rows, row_obj)
        end
    end

    -- 4. Upsert one row per bucket. ON CONFLICT DO UPDATE (not DO
    -- NOTHING) because a re-run must replace the array, not skip it —
    -- otherwise a user's fresh row added to tax_form_items post-first-
    -- backfill would never appear in the profile-builder shadow.
    local stats = { answers = 0, skipped_buckets = 0 }
    for _, key in ipairs(order_seen) do
        local b = buckets[key]
        local qid = q_id_by_key[b.mapping.question_key]
        local user_uuid = user_uuid_by_id[b.user_id]
        if not qid or not user_uuid then
            stats.skipped_buckets = stats.skipped_buckets + 1
        else
            local json_str = cjson.encode(b.rows)
            -- No `source` column on user_profile_answers to mark
            -- backfilled rows — identity of a pension backfilled row
            -- is (question_id ∈ pp_*_payments question_keys) plus the
            -- answer_scope='year' partial index. Phase 3's retirement
            -- filters on those to identify what to drop, so no marker
            -- column is needed here.
            -- answer_json column is TEXT, not jsonb — no cast needed.
            -- Matches how routes/profile-builder.lua's upsert writer
            -- passes the value (see :3303 in that file).
            local ok = pcall(db.query, [[
                INSERT INTO user_profile_answers
                    (uuid, user_id, user_uuid, namespace_id, question_id,
                     entity_uuid, tax_year, answer_json,
                     is_draft, created_at, updated_at)
                VALUES (gen_random_uuid()::text, ?, ?, ?, ?,
                        NULL, ?, ?,
                        false, NOW(), NOW())
                ON CONFLICT (user_id, question_id, tax_year)
                WHERE entity_uuid IS NULL AND tax_year IS NOT NULL
                DO UPDATE SET
                    answer_json = EXCLUDED.answer_json,
                    updated_at = NOW()
            ]], b.user_id, user_uuid, b.namespace_id or db.NULL, qid,
                b.tax_year, json_str)
            if ok then
                stats.answers = stats.answers + 1
            else
                stats.skipped_buckets = stats.skipped_buckets + 1
            end
        end
    end

    print(string.format(
        "[Pension backfill] Ported %d aggregated answers (from %d source items). Skipped %d buckets.",
        stats.answers, #items, stats.skipped_buckets
    ))
end

return {
    -- =========================================================================
    -- 1. Original backfill pass. Registered as 763 in migrations.lua.
    -- =========================================================================
    [1] = backfill_pension,

    -- =========================================================================
    -- 2. Re-run pass. Registered as 765 in migrations.lua. Idempotent
    --    for the same reason as [1]: ON CONFLICT DO UPDATE rebuilds
    --    the aggregated JSON from current tax_form_items state.
    -- =========================================================================
    [2] = backfill_pension,
}
