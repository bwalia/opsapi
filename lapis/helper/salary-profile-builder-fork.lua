--[[
  Salary → Profile Builder — dual-write fork.

  Wraps the primary tax_form_records write path for income_type='salary'
  and mirrors the row into the unified Profile Builder store
  (user_profile_entities + user_profile_answers) so the shadow engine
  stays current during the Phase 1 migration window.

  Gated by IncomeEngine.dual_write_enabled("salary") — off by default,
  turned on per env via the INCOME_ENGINE_SALARY_DUAL_WRITE env var
  (see docs/PROFILE_BUILDER_UNIFICATION_PLAN.md §4 in the
  diy-tax-return-uk repo, and lapis/helper/income-engine.lua here).

  Design rules:

    1. NEVER breaks the primary write. Every entry point pcalls the
       DB work. On failure, the primary write still succeeds and we
       log the discrepancy — the design doc's mismatch counter
       tolerates this and blocks cutover if it doesn't clear.

    2. Same deterministic entity UUID derivation as the backfill
       (`salary-profile-builder-backfill.lua`). A record that was
       backfilled once and later edited by the user via form-records
       ends up with the ONE entity row + updated answers — no
       duplicates.

    3. ON CONFLICT DO UPDATE on answers (not DO NOTHING as the
       backfill uses). The user just wrote a new value on the
       primary; the shadow MUST reflect it. Backfill's DO NOTHING
       was there so a re-run wouldn't overwrite the user's later
       edits on the profile-builder side — for the fork, the user's
       edit IS the source of truth and must propagate.

    4. Field mapping is DUPLICATED in this file and the backfill on
       purpose. The two run in different execution contexts (routes
       vs migrations) and share no other code. A single source-of-
       truth constant would introduce a require-cycle risk between
       queries + migrations. Cost: both places must be kept in sync.
       Mitigation: dev checklist called out in the design doc and a
       test that asserts both maps are equal (added in Phase 2's
       shared-utility pass).

  Public API:

      SalaryFork.on_create(record)     -- record is the freshly-created tax_form_records row
      SalaryFork.on_update(record)     -- record is the just-updated row
      SalaryFork.on_delete(record)     -- record is the pre-delete row (we need its uuid + user)

  Every entry point is safe to call unconditionally — the flag check
  is inside the helper.
]]

local db = require("lapis.db")
local cjson = require("cjson")
local IncomeEngine = require("helper.income-engine")

local M = {}

-- Same key set as salary-profile-builder-backfill.lua's FIELD_MAP.
-- Keep aligned by hand or via the Phase-2 shared-utility check.
local FIELD_MAP = {
    employer_name             = { key = "emp_employer_name",         type = "text" },
    paye_reference            = { key = "emp_paye_reference",        type = "text" },
    start_date                = { key = "emp_start_date",            type = "date" },
    end_date                  = { key = "emp_end_date",              type = "date" },
    is_director               = { key = "emp_is_director",           type = "boolean" },
    director_ceased_date      = { key = "emp_director_ceased_date",  type = "date" },
    is_close_company          = { key = "emp_is_close_company",      type = "boolean" },
    registered_number         = { key = "emp_cc_registered_number",  type = "text" },
    close_company_dividends   = { key = "emp_cc_dividends",          type = "number" },
    shareholding_percent      = { key = "emp_cc_shareholding_percent", type = "number" },
    pay_before_tax            = { key = "emp_pay_before_tax",        type = "number" },
    payrolled_benefits        = { key = "emp_payrolled_benefits",    type = "number" },
    uk_tax_taken_off          = { key = "emp_uk_tax_taken_off",      type = "number" },
    tips_not_on_p60           = { key = "emp_tips_not_on_p60",       type = "number" },
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
    business_travel           = { key = "emp_exp_business_travel",       type = "number" },
    hotel_meal_expenses       = { key = "emp_exp_hotel_meal",            type = "number" },
    fixed_deductions          = { key = "emp_exp_fixed_deductions",      type = "number" },
    professional_fees_subs    = { key = "emp_exp_professional_fees",     type = "number" },
    tools_work_clothes        = { key = "emp_exp_tools_clothes",         type = "number" },
    vehicle_expenses          = { key = "emp_exp_vehicle",               type = "number" },
    mileage_shortfall         = { key = "emp_exp_mileage_shortfall",     type = "number" },
    other_expenses_capital    = { key = "emp_exp_other_capital",         type = "number" },
    seafarers_deduction         = { key = "emp_foreign_seafarers",         type = "number" },
    foreign_earnings_not_taxable = { key = "emp_foreign_not_taxable",      type = "number" },
    foreign_tax_no_credit       = { key = "emp_foreign_tax_no_credit",     type = "number" },
    exempt_overseas_pension     = { key = "emp_foreign_exempt_pension",    type = "number" },
    tax_return_note           = { key = "emp_tax_return_note",       type = "text" },
}

-- Deterministic entity UUID from the source record uuid — matches
-- salary-profile-builder-backfill.lua's deriveEntityUuid exactly.
-- If the two ever drift, backfilled rows and fork rows will land on
-- different entities, doubling storage silently.
local function derive_entity_uuid(record_uuid)
    local rows = db.query([[
        WITH h AS (SELECT md5('phase1-employment:' || ?) AS hex)
        SELECT substring(hex FROM 1  FOR 8)  || '-' ||
               substring(hex FROM 9  FOR 4)  || '-' ||
               substring(hex FROM 13 FOR 4)  || '-' ||
               substring(hex FROM 17 FOR 4)  || '-' ||
               substring(hex FROM 21 FOR 12) AS derived_uuid
        FROM h
    ]], record_uuid)
    return rows[1] and rows[1].derived_uuid or nil
end

local function coerce(field_type, raw)
    if raw == nil or raw == cjson.null then return nil end
    if field_type == "number" then
        local n = tonumber(raw)
        if n and n == n then return n end
        return nil
    end
    if field_type == "text" then
        if type(raw) == "string" then return raw end
        return tostring(raw)
    end
    if field_type == "boolean" then
        if raw == true or raw == false then return raw end
        if raw == "true" then return true end
        if raw == "false" then return false end
        return nil
    end
    if field_type == "date" then
        if type(raw) == "string" and raw ~= "" then return raw end
    end
    return nil
end

-- Log a fork failure to the same channel the design doc's discrepancy
-- counter tallies. Keeps the primary write on its happy path but makes
-- the miss visible for the cutover gate.
local function log_mismatch(op, record_uuid, err)
    ngx.log(ngx.ERR, string.format(
        "[SalaryFork] INCOME_ENGINE_DUAL_WRITE_MISMATCH op=%s record=%s err=%s",
        op, tostring(record_uuid), tostring(err)
    ))
end

-- Upsert the entity row + one answer row per known field value.
local function upsert_entity_and_answers(record)
    local entity_uuid = derive_entity_uuid(record.uuid)
    if not entity_uuid then return false, "derive_entity_uuid failed" end

    local urows = db.query("SELECT uuid FROM users WHERE id = ? LIMIT 1", record.user_id)
    if not urows or #urows == 0 then return false, "user not found" end
    local user_uuid = urows[1].uuid

    local data
    if type(record.data_json) == "string" then
        local ok, decoded = pcall(cjson.decode, record.data_json)
        if not ok then return false, "invalid data_json" end
        data = decoded
    else
        data = record.data_json or {}
    end
    if type(data) ~= "table" then return false, "data_json not an object" end

    local label = data.employer_name
    if type(label) ~= "string" or label == "" then label = "Employment" end
    if #label > 200 then label = label:sub(1, 200) end
    local metadata = cjson.encode({
        origin = "phase1_salary_fork",
        legacy_form_record_uuid = record.uuid,
    })

    db.query([[
        INSERT INTO user_profile_entities
            (uuid, user_id, user_uuid, namespace_id, entity_type,
             label, metadata_json, display_order, is_archived,
             created_at, updated_at)
        VALUES (?, ?, ?, ?, 'employment', ?, ?, 0, false, NOW(), NOW())
        ON CONFLICT (uuid) DO UPDATE
        SET label = EXCLUDED.label,
            metadata_json = EXCLUDED.metadata_json,
            is_archived = false,
            archived_at = NULL,
            updated_at = NOW()
    ]], entity_uuid, record.user_id, user_uuid,
        record.namespace_id or db.NULL, label, metadata)

    -- Batch the question-id lookup — a single SELECT for every
    -- known question_key (small fixed set) is cheaper than one per
    -- data field.
    local keys_list = {}
    for _, m in pairs(FIELD_MAP) do keys_list[#keys_list + 1] = m.key end
    local qrows = db.query(
        "SELECT id, question_key FROM profile_questions WHERE question_key = ANY(?)",
        db.array(keys_list)
    ) or {}
    local qid_by_key = {}
    for _, qr in ipairs(qrows) do qid_by_key[qr.question_key] = qr.id end

    for field_key, raw in pairs(data) do
        local mapping = FIELD_MAP[field_key]
        if mapping then
            local qid = qid_by_key[mapping.key]
            local typed = coerce(mapping.type, raw)
            if qid and typed ~= nil then
                local col_text, col_num, col_bool, col_date =
                    db.NULL, db.NULL, db.NULL, db.NULL
                if mapping.type == "text" then col_text = typed
                elseif mapping.type == "number" then col_num = typed
                elseif mapping.type == "boolean" then col_bool = typed
                elseif mapping.type == "date" then col_date = typed
                end
                -- Fork is authoritative for the primary user's write —
                -- ON CONFLICT DO UPDATE, not DO NOTHING like backfill.
                --
                -- The conflict target `idx_upa_user_question_entity` is a
                -- PARTIAL unique index (WHERE entity_uuid IS NOT NULL),
                -- not a constraint — Postgres's `ON CONFLICT ON
                -- CONSTRAINT <name>` doesn't accept indexes. We use the
                -- inferred form with a matching index_predicate so
                -- Postgres uniquely identifies the partial index.
                db.query([[
                    INSERT INTO user_profile_answers
                        (uuid, user_id, user_uuid, namespace_id,
                         question_id, question_version, entity_uuid,
                         answer_text, answer_number, answer_boolean,
                         answer_date, is_draft, answered_at, updated_at)
                    VALUES (gen_random_uuid()::text, ?, ?, ?, ?, 1, ?,
                            ?, ?, ?, ?, false, NOW(), NOW())
                    ON CONFLICT (user_id, question_id, entity_uuid)
                    WHERE entity_uuid IS NOT NULL
                    DO UPDATE SET
                        answer_text = EXCLUDED.answer_text,
                        answer_number = EXCLUDED.answer_number,
                        answer_boolean = EXCLUDED.answer_boolean,
                        answer_date = EXCLUDED.answer_date,
                        updated_at = NOW()
                ]], record.user_id, user_uuid, record.namespace_id or db.NULL,
                    qid, entity_uuid,
                    col_text, col_num, col_bool, col_date)
            end
        end
        -- Unknown / unmapped fields are silently dropped — the shadow
        -- catalogue is the source of truth; anything the primary knows
        -- but the shadow doesn't is not our problem to preserve.
    end

    return true, entity_uuid
end

-- Archive the entity + its answers. Same idempotent shape — a re-run
-- (or a delete on an already-archived record) is a no-op.
local function archive_entity(record)
    local entity_uuid = derive_entity_uuid(record.uuid)
    if not entity_uuid then return false, "derive_entity_uuid failed" end
    db.query([[
        UPDATE user_profile_entities
        SET is_archived = true, archived_at = NOW(), updated_at = NOW()
        WHERE uuid = ? AND is_archived = false
    ]], entity_uuid)
    -- We do NOT delete answer rows — they hang off entity_uuid and the
    -- unique-index still holds. Leaving them lets a Phase-1 rollback
    -- restore the record cheaply. Phase 3's cleanup drops them.
    return true, entity_uuid
end

-- Public entry points -------------------------------------------------

--- Called after a successful POST /form-records. `record` is the row
--- FormSectionQueries.create_record returned (uuid, user_id, tax_year,
--- income_type_key, data_json, namespace_id).
function M.on_create(record)
    if not record or record.income_type_key ~= "salary" then return end
    if not IncomeEngine.dual_write_enabled("salary") then return end
    local ok, err = pcall(upsert_entity_and_answers, record)
    if not ok then log_mismatch("create", record.uuid, err) end
end

--- Called after a successful PUT /form-records/:uuid. `record` is the
--- updated row (same shape as create).
function M.on_update(record)
    if not record or record.income_type_key ~= "salary" then return end
    if not IncomeEngine.dual_write_enabled("salary") then return end
    local ok, err = pcall(upsert_entity_and_answers, record)
    if not ok then log_mismatch("update", record.uuid, err) end
end

--- Called after a successful DELETE /form-records/:uuid. Pass the
--- pre-delete record so we know which entity to archive.
function M.on_delete(record)
    if not record or record.income_type_key ~= "salary" then return end
    if not IncomeEngine.dual_write_enabled("salary") then return end
    local ok, err = pcall(archive_entity, record)
    if not ok then log_mismatch("delete", record.uuid, err) end
end

return M
