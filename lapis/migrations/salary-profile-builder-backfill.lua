--[[
  Salary / Employment — Phase 1 backfill.

  Copies every existing `tax_form_records WHERE income_type_key='salary'`
  row into the unified Profile Builder store:

    tax_form_records row (JSON blob `data_json`)
      → user_profile_entities row (entity_type='employment')
      +  one user_profile_answers row per known question_key present
         in `data_json`, typed correctly per the question's type.

  The source rows are LEFT IN PLACE. Retirement is Phase 3's job, after
  the profile-builder-served page has been live in prod for 14+ days
  and the discrepancy log for INCOME_ENGINE_SALARY_DUAL_WRITE has been
  clean.

  Idempotency
    - New entity uuid is DETERMINISTIC — a namespaced UUIDv5-style
      derivation from the source record's uuid. Re-running the
      migration produces the same target uuid, so the ON CONFLICT
      guards skip cleanly.
    - Answer inserts use the existing partial unique indexes on
      (user_id, question_id, entity_uuid) — `ON CONFLICT DO NOTHING`
      makes a second run a no-op.
    - Backfill can be re-run any time without corrupting state; safe
      to run before dual-write is enabled, during the dual-write
      window, or after cutover as a repair pass.

  Reversibility
    - `deriveEntityUuid` is documented so the reverse walk (Phase 3
      or an emergency rollback) can identify which entities came from
      the backfill vs. which were created via the new page.
    - Rollback: mark those entities `is_archived=true`, delete their
      answers, done. See docs/PROFILE_BUILDER_UNIFICATION_PLAN.md §6.

  Field-mapping table
    Each key here mirrors what salary-employment-system.lua's
    ensure_section() puts in `data_json`. If an admin has added new
    fields to the tax_form_sections config since (via /admin/form-
    sections), those field values are DROPPED by this backfill — the
    catalog migration seeds the same names into Profile Builder so
    only fields BOTH sides know about survive. That's an intentional
    safety-first choice; add the field on both sides + re-run the
    backfill if you need to preserve a custom field.

  Only executed when PROJECT_CODE includes 'tax_copilot'.
]]

local db = require("lapis.db")
local cjson = require("cjson")

-- Map: tax_form_records data_json field key → { question_key, type }
-- The tuple's `type` decides which typed column on user_profile_answers
-- gets populated (answer_number / answer_text / answer_boolean /
-- answer_date). Do NOT rename these — they are the exact keys the old
-- salary-employment-system.lua wrote and the exact question_keys the
-- Phase-1 catalog migration created.
local FIELD_MAP = {
    -- Employment details
    employer_name             = { key = "emp_employer_name",         type = "text" },
    paye_reference            = { key = "emp_paye_reference",        type = "text" },
    start_date                = { key = "emp_start_date",            type = "date" },
    end_date                  = { key = "emp_end_date",              type = "date" },
    is_director               = { key = "emp_is_director",           type = "boolean" },
    director_ceased_date      = { key = "emp_director_ceased_date",  type = "date" },
    is_close_company          = { key = "emp_is_close_company",      type = "boolean" },
    -- Close company details
    registered_number         = { key = "emp_cc_registered_number",  type = "text" },
    close_company_dividends   = { key = "emp_cc_dividends",          type = "number" },
    shareholding_percent      = { key = "emp_cc_shareholding_percent", type = "number" },
    -- Income
    pay_before_tax            = { key = "emp_pay_before_tax",        type = "number" },
    payrolled_benefits        = { key = "emp_payrolled_benefits",    type = "number" },
    uk_tax_taken_off          = { key = "emp_uk_tax_taken_off",      type = "number" },
    tips_not_on_p60           = { key = "emp_tips_not_on_p60",       type = "number" },
    -- Benefits
    company_cars              = { key = "emp_ben_company_cars",          type = "number" },
    fuel_company_cars         = { key = "emp_ben_fuel_company_cars",     type = "number" },
    company_vans              = { key = "emp_ben_company_vans",          type = "number" },
    fuel_company_vans         = { key = "emp_ben_fuel_company_vans",     type = "number" },
    travel_subsistence        = { key = "emp_ben_travel_subsistence",    type = "number" },
    entertaining              = { key = "emp_ben_entertaining",          type = "number" },
    private_medical           = { key = "emp_ben_private_medical",       type = "number" },
    telephone                 = { key = "emp_ben_telephone",             type = "number" },
    professional_fees_employer = { key = "emp_ben_professional_fees",     type = "number" },
    vouchers_credit_cards     = { key = "emp_ben_vouchers_credit_cards", type = "number" },
    excess_mileage_allowance  = { key = "emp_ben_excess_mileage",        type = "number" },
    goods_assets_provided     = { key = "emp_ben_goods_assets",          type = "number" },
    accommodation_provided    = { key = "emp_ben_accommodation",         type = "number" },
    other_benefits            = { key = "emp_ben_other",                 type = "number" },
    expenses_payments_received = { key = "emp_ben_expenses_payments",    type = "number" },
    -- Expenses
    business_travel           = { key = "emp_exp_business_travel",       type = "number" },
    hotel_meal_expenses       = { key = "emp_exp_hotel_meal",            type = "number" },
    fixed_deductions          = { key = "emp_exp_fixed_deductions",      type = "number" },
    professional_fees_subs    = { key = "emp_exp_professional_fees",     type = "number" },
    tools_work_clothes        = { key = "emp_exp_tools_clothes",         type = "number" },
    vehicle_expenses          = { key = "emp_exp_vehicle",               type = "number" },
    mileage_shortfall         = { key = "emp_exp_mileage_shortfall",     type = "number" },
    other_expenses_capital    = { key = "emp_exp_other_capital",         type = "number" },
    -- Foreign
    seafarers_deduction         = { key = "emp_foreign_seafarers",         type = "number" },
    foreign_earnings_not_taxable = { key = "emp_foreign_not_taxable",      type = "number" },
    foreign_tax_no_credit       = { key = "emp_foreign_tax_no_credit",     type = "number" },
    exempt_overseas_pension     = { key = "emp_foreign_exempt_pension",    type = "number" },
    -- Notes
    tax_return_note           = { key = "emp_tax_return_note",       type = "text" },
}

-- Deterministic UUID for the target entity so re-runs cleanly ON CONFLICT
-- DO NOTHING. Same input → same output, always. Uses built-in md5()
-- (32 hex chars) reformatted into UUID shape — no pgcrypto dependency
-- (some pods don't have the extension enabled). Namespace prefix
-- 'phase1-employment:' ensures the derived uuid can't collide with any
-- other migration that might hash the same source uuid for a different
-- purpose.
--
-- The reverse walk (Phase 3 or emergency rollback) identifies these
-- entities via user_profile_entities.metadata_json.origin, not by
-- attempting to reverse the hash.
local function deriveEntityUuid(source_uuid)
    local rows = db.query([[
        WITH h AS (SELECT md5('phase1-employment:' || ?) AS hex)
        SELECT substring(hex FROM 1  FOR 8)  || '-' ||
               substring(hex FROM 9  FOR 4)  || '-' ||
               substring(hex FROM 13 FOR 4)  || '-' ||
               substring(hex FROM 17 FOR 4)  || '-' ||
               substring(hex FROM 21 FOR 12) AS derived_uuid
        FROM h
    ]], source_uuid)
    return rows[1].derived_uuid
end

-- Coerce a JSON value to something the typed column accepts. Returns
-- (typed_value_for_the_named_column, nil) on success; (nil, reason)
-- when the value can't be represented in that column type (row is
-- silently skipped — better to lose one bad value than block the
-- backfill).
local function coerce(field_type, raw)
    if raw == nil or raw == cjson.null then return nil, "null" end
    if field_type == "number" then
        local n = tonumber(raw)
        if n and n == n then return n, nil end -- reject NaN
        return nil, "not a number"
    end
    if field_type == "text" then
        if type(raw) == "string" then return raw, nil end
        return tostring(raw), nil
    end
    if field_type == "boolean" then
        if raw == true or raw == false then return raw, nil end
        if raw == "true" then return true, nil end
        if raw == "false" then return false, nil end
        return nil, "not a boolean"
    end
    if field_type == "date" then
        if type(raw) == "string" and raw ~= "" then return raw, nil end
        return nil, "empty date"
    end
    return nil, "unknown field type"
end

return {
    -- =========================================================================
    -- 1. Walk every non-archived salary record → insert entity + answers.
    -- =========================================================================
    [1] = function()
        local rows = db.query([[
            SELECT id, uuid, user_id, namespace_id, tax_year, data_json,
                   created_at, updated_at
            FROM tax_form_records
            WHERE income_type_key = 'salary' AND is_archived = false
        ]]) or {}

        if #rows == 0 then
            print("[Salary backfill] Nothing to backfill (0 salary records).")
            return
        end

        -- Question id lookup: question_key → id. Batched to a single
        -- SELECT so a re-run doesn't scan profile_questions per row.
        local q_lookup = {}
        for _, m in pairs(FIELD_MAP) do q_lookup[m.key] = true end
        local keys_list = {}
        for k in pairs(q_lookup) do keys_list[#keys_list + 1] = k end
        local question_rows = db.query(
            "SELECT id, question_key FROM profile_questions WHERE question_key = ANY(?)",
            db.array(keys_list)
        ) or {}
        local qid_by_key = {}
        for _, qr in ipairs(question_rows) do
            qid_by_key[qr.question_key] = qr.id
        end
        if next(qid_by_key) == nil then
            print("[Salary backfill] Question catalog not seeded yet — skipping " ..
                  #rows .. " records. Re-run after the seed migration lands.")
            return
        end

        -- Look up the user's uuid once per unique user_id in the batch.
        local user_uuid_by_id = {}
        for _, r in ipairs(rows) do user_uuid_by_id[r.user_id] = true end
        local uid_list = {}
        for uid in pairs(user_uuid_by_id) do uid_list[#uid_list + 1] = uid end
        local uuid_rows = db.query(
            "SELECT id, uuid FROM users WHERE id = ANY(?)", db.array(uid_list)
        ) or {}
        for _, ur in ipairs(uuid_rows) do user_uuid_by_id[ur.id] = ur.uuid end

        local stats = { entities = 0, answers = 0, skipped_rows = 0, skipped_fields = 0 }

        for _, r in ipairs(rows) do
            local ok, data = pcall(cjson.decode, r.data_json or "{}")
            if not ok or type(data) ~= "table" then
                stats.skipped_rows = stats.skipped_rows + 1
            else
                local user_uuid = user_uuid_by_id[r.user_id]
                if type(user_uuid) ~= "string" then
                    stats.skipped_rows = stats.skipped_rows + 1
                else
                    local entity_uuid = deriveEntityUuid(r.uuid)
                    local label = data.employer_name
                    if type(label) ~= "string" or label == "" then label = "Employment" end
                    if #label > 200 then label = label:sub(1, 200) end
                    local metadata = cjson.encode({
                        origin = "phase1_salary_backfill",
                        legacy_form_record_uuid = r.uuid,
                    })

                    -- Entity row — ON CONFLICT DO NOTHING makes re-runs safe.
                    -- namespace_id can be null; propagate as-is.
                    db.query([[
                        INSERT INTO user_profile_entities
                            (uuid, user_id, user_uuid, namespace_id, entity_type,
                             label, metadata_json, display_order, is_archived,
                             created_at, updated_at)
                        VALUES (?, ?, ?, ?, 'employment', ?, ?, 0, false, ?, ?)
                        ON CONFLICT (uuid) DO NOTHING
                    ]], entity_uuid, r.user_id, user_uuid,
                        r.namespace_id or db.NULL, label, metadata,
                        r.created_at, r.updated_at)
                    stats.entities = stats.entities + 1

                    for field_key, value in pairs(data) do
                        local mapping = FIELD_MAP[field_key]
                        if not mapping then
                            stats.skipped_fields = stats.skipped_fields + 1
                        else
                            local qid = qid_by_key[mapping.key]
                            local typed_value, _ = coerce(mapping.type, value)
                            if qid and typed_value ~= nil then
                                -- One partial unique index guards this:
                                -- (user_id, question_id, entity_uuid) WHERE
                                -- entity_uuid IS NOT NULL. ON CONFLICT DO
                                -- NOTHING makes a re-run a no-op — we never
                                -- overwrite a value the user may have edited
                                -- on the profile-builder side after backfill.
                                local col_text, col_num, col_bool, col_date =
                                    db.NULL, db.NULL, db.NULL, db.NULL
                                if mapping.type == "text" then col_text = typed_value
                                elseif mapping.type == "number" then col_num = typed_value
                                elseif mapping.type == "boolean" then col_bool = typed_value
                                elseif mapping.type == "date" then col_date = typed_value
                                end
                                db.query([[
                                    INSERT INTO user_profile_answers
                                        (uuid, user_id, user_uuid, namespace_id,
                                         question_id, question_version, entity_uuid,
                                         answer_text, answer_number, answer_boolean,
                                         answer_date, is_draft, answered_at, updated_at)
                                    VALUES (gen_random_uuid()::text, ?, ?, ?, ?, 1, ?,
                                            ?, ?, ?, ?, false, ?, ?)
                                    ON CONFLICT DO NOTHING
                                ]], r.user_id, user_uuid, r.namespace_id or db.NULL,
                                    qid, entity_uuid,
                                    col_text, col_num, col_bool, col_date,
                                    r.created_at, r.updated_at)
                                stats.answers = stats.answers + 1
                            elseif not qid then
                                stats.skipped_fields = stats.skipped_fields + 1
                            end
                        end
                    end
                end
            end
        end

        print(string.format(
            "[Salary backfill] Ported %d entities + %d answers. Skipped %d rows, %d unknown fields.",
            stats.entities, stats.answers, stats.skipped_rows, stats.skipped_fields
        ))
    end,
}
