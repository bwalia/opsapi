--[[
    Employment Queries — user_profile_entities rows of entity_type 'employment'.

    An "employment" is the drill-down unit of the Salary income hub — one
    row per PAYE job the taxpayer held during the year. Each carries:
      * a user-facing label (nickname / employer name shown in the hub list)
      * entity-scoped Profile Builder answers via user_profile_answers.entity_uuid
        (the 42 fields seeded by migration 758)

    Unlike properties and businesses, employments have NO line items — every
    figure is one answer against a Profile Builder question, so there's no
    parallel to property_line_items / business_line_values here. Deliberately
    kept separate from PropertyQueries so this module never grows a
    "if entity_type == 'employment' then skip line items" shim.

    Every read/write is user-scoped. Soft-delete via is_archived so
    entity-scoped answers keep a resolvable parent for historical
    calculations.
]]

local Global = require "helper.global"
local TaxAuditLogQueries = require "queries.TaxAuditLogQueries"
local db = require("lapis.db")
local cjson = require("cjson")

local EmploymentQueries = {}
local ENTITY_TYPE = "employment"
local AUDIT_LABEL = "EMPLOYMENT"

local function resolveUserId(user)
    if not user then return nil, "User not authenticated" end
    local user_uuid = user.uuid or user.id
    local rows
    if user.uuid then
        rows = db.query("SELECT id FROM users WHERE uuid = ? LIMIT 1", user_uuid)
    else
        rows = db.query("SELECT id FROM users WHERE id = ? LIMIT 1", user_uuid)
    end
    if not rows or #rows == 0 then return nil, "User not found" end
    return rows[1].id
end

local function resolveNamespaceId(internal_user_id)
    local rows = db.query([[
        SELECT default_namespace_id FROM user_namespace_settings
        WHERE user_id = ? LIMIT 1
    ]], internal_user_id)
    if rows and #rows > 0 and rows[1].default_namespace_id then
        return tonumber(rows[1].default_namespace_id)
    end
    return nil
end

local function present(row)
    row.id = row.uuid
    row.user_id = nil
    return row
end

-- ────────────────────────────────────────────────────────────────────────────
-- List — used by the hub.
--
-- When `params.tax_year` is provided (YYYY-YY), each row is decorated
-- with derived totals for the employment:
--
--   pay_total     SUM of emp_pay_before_tax + emp_tips_not_on_p60
--                 (matches salary-employment-system.lua's `summary=true`
--                 flag on those two SA102 boxes — the classic "salary
--                 income" figure the /my-income overview cares about).
--   benefits_total  SUM of every emp_ben_* field (BIK on P11D)
--   expenses_total  SUM of every emp_exp_* field
--   income_total  pay + benefits (the taxable side of the employment)
--   net_total     income_total - expenses_total  (what actually gets
--                 taxed for this employment after allowable expenses)
--
-- One aggregated SQL query pulls every relevant row for every listed
-- employment in a single round-trip; no N+1 per employment. Rows are
-- keyed on (entity_uuid, question_key) so the frontend can also
-- render a per-employment card without a second call.
--
-- If tax_year is omitted, totals are omitted too — some callers only
-- want the identifiers.
-- ────────────────────────────────────────────────────────────────────────────
local SALARY_PAY_KEYS = { "emp_pay_before_tax", "emp_tips_not_on_p60" }

function EmploymentQueries.all(params, user)
    local internal_user_id, err = resolveUserId(user)
    if not internal_user_id then return nil, err end

    local where = { "user_id = ?", "entity_type = ?" }
    local args = { internal_user_id, ENTITY_TYPE }
    if params.include_archived ~= "true" and params.include_archived ~= true then
        table.insert(where, "is_archived = false")
    end

    local rows = db.query(
        "SELECT * FROM user_profile_entities WHERE " .. table.concat(where, " AND ")
        .. " ORDER BY display_order ASC, created_at ASC",
        unpack(args)) or {}

    -- Zero out the totals slot on every row up-front so the frontend
    -- doesn't have to distinguish "not requested" from "requested but
    -- empty". Whether we populate them depends on tax_year being set.
    for _, r in ipairs(rows) do
        r.pay_total = 0
        r.benefits_total = 0
        r.expenses_total = 0
        r.income_total = 0
        r.net_total = 0
        present(r)
    end

    -- Derived totals only when a tax_year is requested. Some scopes on
    -- the employment questions are per-entity (evergreen — e.g. employer
    -- name), others are per-entity per-year (e.g. pay figures) — the
    -- year-scoped ones are the ones that sum to a total. We filter the
    -- answer set on (entity_uuid IN listed, question_key LIKE 'emp_%')
    -- and let PostgreSQL do the grouping.
    if params.tax_year and params.tax_year ~= "" and #rows > 0 then
        local uuid_list = {}
        for _, r in ipairs(rows) do uuid_list[#uuid_list + 1] = r.uuid end
        local ans = db.query([[
            SELECT a.entity_uuid, q.question_key,
                   COALESCE(a.answer_number, 0) AS amount
            FROM user_profile_answers a
            JOIN profile_questions q ON q.id = a.question_id
            WHERE a.user_id = ?
              AND a.entity_uuid = ANY(?)
              AND (a.tax_year = ? OR a.tax_year IS NULL)
              AND (q.question_key LIKE 'emp_pay_%'
                   OR q.question_key = 'emp_tips_not_on_p60'
                   OR q.question_key LIKE 'emp_ben_%'
                   OR q.question_key LIKE 'emp_exp_%')
              AND a.answer_number IS NOT NULL
        ]], internal_user_id, db.array(uuid_list), params.tax_year) or {}

        local by_uuid = {}
        for _, r in ipairs(rows) do by_uuid[r.uuid] = r end

        for _, a in ipairs(ans) do
            local entity = by_uuid[a.entity_uuid]
            if entity then
                local amount = tonumber(a.amount) or 0
                local qk = a.question_key
                if qk == "emp_pay_before_tax" or qk == "emp_tips_not_on_p60" then
                    entity.pay_total = entity.pay_total + amount
                elseif qk:sub(1, 8) == "emp_ben_" then
                    entity.benefits_total = entity.benefits_total + amount
                elseif qk:sub(1, 8) == "emp_exp_" then
                    entity.expenses_total = entity.expenses_total + amount
                end
            end
        end

        for _, r in ipairs(rows) do
            r.income_total = r.pay_total + r.benefits_total
            r.net_total = r.income_total - r.expenses_total
        end
    end

    return { data = rows, total = #rows }
end

-- Aggregate across every non-archived employment for a user + tax year.
-- Used by /my-income to swap the legacy tax_form_records-based salary
-- total with the profile-builder-sourced one for migrated envs. Same
-- key set as EmploymentQueries.all's total decoration — kept in step
-- via SALARY_PAY_KEYS + the emp_ben_/emp_exp_ prefixes below.
function EmploymentQueries.aggregate_income_total(user, tax_year)
    local internal_user_id, err = resolveUserId(user)
    if not internal_user_id then return nil, err end

    -- Two SUMs: pay (pay_before_tax + tips) and benefits (emp_ben_*).
    -- Matches the "summary=true" fields in the legacy salary-employment-
    -- system.lua catalog + BIK. Expenses are DEDUCTIONS, tracked
    -- separately so /my-income can show gross income (matches the
    -- pre-Phase-1 card total).
    local pay_placeholders = "'" .. table.concat(SALARY_PAY_KEYS, "','") .. "'"
    local rows = db.query([[
        SELECT
          COALESCE(SUM(CASE
            WHEN q.question_key IN (]] .. pay_placeholders .. [[)
            THEN a.answer_number ELSE 0 END), 0) AS pay_total,
          COALESCE(SUM(CASE
            WHEN q.question_key LIKE 'emp_ben_%'
            THEN a.answer_number ELSE 0 END), 0) AS benefits_total,
          COUNT(DISTINCT a.entity_uuid) AS employment_count
        FROM user_profile_answers a
        JOIN profile_questions q ON q.id = a.question_id
        JOIN user_profile_entities e ON e.uuid = a.entity_uuid
        WHERE a.user_id = ?
          AND e.entity_type = ?
          AND e.is_archived = false
          AND (a.tax_year = ? OR a.tax_year IS NULL)
          AND a.answer_number IS NOT NULL
    ]], internal_user_id, ENTITY_TYPE, tax_year or "") or {}

    local r = rows[1] or {}
    local pay = tonumber(r.pay_total) or 0
    local benefits = tonumber(r.benefits_total) or 0
    return {
        pay_total = pay,
        benefits_total = benefits,
        income_total = pay + benefits,
        employment_count = tonumber(r.employment_count) or 0,
    }
end

function EmploymentQueries.show(employment_uuid, user)
    local internal_user_id, err = resolveUserId(user)
    if not internal_user_id then return nil, err end

    local rows = db.query([[
        SELECT * FROM user_profile_entities
        WHERE uuid = ? AND user_id = ? AND entity_type = ?
        LIMIT 1
    ]], employment_uuid, internal_user_id, ENTITY_TYPE)
    if not rows or #rows == 0 then return nil end
    return present(rows[1])
end

function EmploymentQueries.create(data, user)
    local internal_user_id, err = resolveUserId(user)
    if not internal_user_id then return nil, err end

    if not data.label or data.label == "" then
        return nil, "label is required"
    end

    local uuid = Global.generateUUID()
    db.query([[
        INSERT INTO user_profile_entities
            (uuid, user_id, user_uuid, namespace_id, entity_type, label, metadata_json, display_order, is_archived, created_at, updated_at)
        VALUES (?, ?, ?, ?, ?, ?, ?, ?, false, NOW(), NOW())
    ]],
        uuid,
        internal_user_id,
        tostring(user.uuid or user.id),
        resolveNamespaceId(internal_user_id) or db.NULL,
        ENTITY_TYPE,
        tostring(data.label),
        data.metadata_json or db.NULL,
        tonumber(data.display_order) or 0
    )
    local row = db.query("SELECT * FROM user_profile_entities WHERE uuid = ? LIMIT 1", uuid)[1]

    TaxAuditLogQueries.log({
        user_id = internal_user_id,
        user_email = user.email,
        entity_type = AUDIT_LABEL,
        entity_id = uuid,
        action = "CREATE",
        new_values = cjson.encode(row),
    })
    return present(row)
end

function EmploymentQueries.update(employment_uuid, data, user)
    local internal_user_id, err = resolveUserId(user)
    if not internal_user_id then return nil, err end

    local existing = db.query([[
        SELECT * FROM user_profile_entities
        WHERE uuid = ? AND user_id = ? AND entity_type = ? LIMIT 1
    ]], employment_uuid, internal_user_id, ENTITY_TYPE)
    if not existing or #existing == 0 then return nil end
    local old = existing[1]

    local updates, args = {}, {}
    if data.label ~= nil then
        if data.label == "" then return nil, "label cannot be empty" end
        table.insert(updates, "label = ?"); table.insert(args, tostring(data.label))
    end
    if data.metadata_json ~= nil then
        table.insert(updates, "metadata_json = ?")
        table.insert(args, data.metadata_json ~= "" and data.metadata_json or db.NULL)
    end
    if data.display_order ~= nil then
        table.insert(updates, "display_order = ?"); table.insert(args, tonumber(data.display_order) or 0)
    end
    if #updates == 0 then return present(old) end

    table.insert(updates, "updated_at = NOW()")
    table.insert(args, employment_uuid)
    table.insert(args, internal_user_id)
    db.query("UPDATE user_profile_entities SET " .. table.concat(updates, ", ")
        .. " WHERE uuid = ? AND user_id = ?", unpack(args))

    local refreshed = db.query("SELECT * FROM user_profile_entities WHERE uuid = ? LIMIT 1", employment_uuid)[1]

    TaxAuditLogQueries.log({
        user_id = internal_user_id,
        user_email = user.email,
        entity_type = AUDIT_LABEL,
        entity_id = employment_uuid,
        action = "UPDATE",
        old_values = cjson.encode(old),
        new_values = cjson.encode(refreshed),
    })
    return present(refreshed)
end

-- Soft-delete. Entity-scoped answers are LEFT in place so historical
-- calculations for prior tax years remain reproducible (matches the
-- Property / Business archive contract).
function EmploymentQueries.archive(employment_uuid, user)
    local internal_user_id, err = resolveUserId(user)
    if not internal_user_id then return nil, err end

    local existing = db.query([[
        SELECT * FROM user_profile_entities
        WHERE uuid = ? AND user_id = ? AND entity_type = ? LIMIT 1
    ]], employment_uuid, internal_user_id, ENTITY_TYPE)
    if not existing or #existing == 0 then return nil end

    db.query([[
        UPDATE user_profile_entities
           SET is_archived = true, archived_at = NOW(), updated_at = NOW()
         WHERE uuid = ? AND user_id = ?
    ]], employment_uuid, internal_user_id)

    TaxAuditLogQueries.log({
        user_id = internal_user_id,
        user_email = user.email,
        entity_type = AUDIT_LABEL,
        entity_id = employment_uuid,
        action = "DELETE",
        old_values = cjson.encode(existing[1]),
    })
    return true
end

return EmploymentQueries
