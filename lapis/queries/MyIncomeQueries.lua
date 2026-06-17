--[[
    My Income Queries

    CRUD on my_incomes. Every read/write is scoped to the authenticated
    user (and their default namespace where applicable). Soft-delete via
    is_archived — list endpoints filter archived rows by default, an
    admin / "show archived" flag can include them.

    The aggregation that drives the tax-calc override lives in FastAPI
    (backend/app/services/income_source.py::get_total_income) — it reads
    this table directly via SQLModel. Keep the column names + types
    aligned with what that helper expects.
]]

local Global = require "helper.global"
local MyIncomes = require "models.MyIncomeModel"
local TaxAuditLogQueries = require "queries.TaxAuditLogQueries"
local db = require("lapis.db")
local cjson = require("cjson")

local MyIncomeQueries = {}

-- Resolve internal user.id (int) from LapisUser (which carries uuid).
-- Returns id or nil, error_message.
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

-- Resolve user's default namespace (returns nil if not configured — column allows NULL).
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

-- ────────────────────────────────────────────────────────────────────────────
-- List
-- ────────────────────────────────────────────────────────────────────────────
-- params: { tax_year?, income_type?, include_archived? = "false" }
function MyIncomeQueries.all(params, user)
    local internal_user_id, err = resolveUserId(user)
    if not internal_user_id then return nil, err end

    local where = { "user_id = ?" }
    local args = { internal_user_id }

    if params.tax_year and params.tax_year ~= "" then
        table.insert(where, "tax_year = ?")
        table.insert(args, params.tax_year)
    end
    if params.income_type and params.income_type ~= "" then
        table.insert(where, "income_type = ?")
        table.insert(args, params.income_type)
    end
    -- Default: hide archived
    if params.include_archived ~= "true" and params.include_archived ~= true then
        table.insert(where, "is_archived = false")
    end

    local sql = "SELECT * FROM my_incomes WHERE " .. table.concat(where, " AND ")
        .. " ORDER BY tax_year DESC, created_at DESC"
    local rows = db.query(sql, unpack(args))
    rows = rows or {}

    -- Don't expose internal user_id; expose uuid as `id` for parity with
    -- tax_bank_accounts API responses.
    for _, r in ipairs(rows) do
        r.id = r.uuid
        r.user_id = nil
    end
    return { data = rows, total = #rows }
end

-- ────────────────────────────────────────────────────────────────────────────
-- Show
-- ────────────────────────────────────────────────────────────────────────────
function MyIncomeQueries.show(income_uuid, user)
    local internal_user_id, err = resolveUserId(user)
    if not internal_user_id then return nil, err end

    local rows = db.query([[
        SELECT * FROM my_incomes
        WHERE uuid = ? AND user_id = ?
        LIMIT 1
    ]], income_uuid, internal_user_id)
    if not rows or #rows == 0 then return nil end

    local row = rows[1]
    row.id = row.uuid
    row.user_id = nil
    return row
end

-- ────────────────────────────────────────────────────────────────────────────
-- Create
-- ────────────────────────────────────────────────────────────────────────────
-- Caller must have already validated params (route layer enforces catalogue +
-- amount > 0 + tax_year regex). We re-check amount and required fields
-- defensively in case a different caller wires in later.
function MyIncomeQueries.create(data, user)
    local internal_user_id, err = resolveUserId(user)
    if not internal_user_id then return nil, err end

    if not data.amount or tonumber(data.amount) == nil or tonumber(data.amount) <= 0 then
        return nil, "amount must be a positive number"
    end
    if not data.income_type or data.income_type == "" then
        return nil, "income_type is required"
    end
    if not data.tax_year or data.tax_year == "" then
        return nil, "tax_year is required"
    end

    local row = MyIncomes:create({
        uuid = Global.generateUUID(),
        user_id = internal_user_id,
        namespace_id = data.namespace_id or resolveNamespaceId(internal_user_id),
        amount = tonumber(data.amount),
        income_type = data.income_type,
        tax_year = data.tax_year,
        description = data.description,
        is_archived = false,
    }, { returning = "*" })

    TaxAuditLogQueries.log({
        user_id = internal_user_id,
        user_email = user.email,
        entity_type = "MY_INCOME",
        entity_id = row.uuid,
        action = "CREATE",
        new_values = cjson.encode(row),
    })

    row.id = row.uuid
    row.user_id = nil
    return row
end

-- ────────────────────────────────────────────────────────────────────────────
-- Update
-- ────────────────────────────────────────────────────────────────────────────
-- Only allows the user's own rows. Returns nil if not found or not owned.
function MyIncomeQueries.update(income_uuid, data, user)
    local internal_user_id, err = resolveUserId(user)
    if not internal_user_id then return nil, err end

    local existing = db.query([[
        SELECT * FROM my_incomes WHERE uuid = ? AND user_id = ? LIMIT 1
    ]], income_uuid, internal_user_id)
    if not existing or #existing == 0 then return nil end
    local old = existing[1]

    local updates = {}
    local args = {}
    if data.amount ~= nil then
        local n = tonumber(data.amount)
        if not n or n <= 0 then return nil, "amount must be a positive number" end
        table.insert(updates, "amount = ?"); table.insert(args, n)
    end
    if data.income_type then
        table.insert(updates, "income_type = ?"); table.insert(args, data.income_type)
    end
    if data.tax_year then
        table.insert(updates, "tax_year = ?"); table.insert(args, data.tax_year)
    end
    if data.description ~= nil then
        table.insert(updates, "description = ?"); table.insert(args, data.description)
    end
    if #updates == 0 then
        -- Nothing to do — return the unchanged row.
        old.id = old.uuid; old.user_id = nil
        return old
    end
    table.insert(updates, "updated_at = NOW()")
    table.insert(args, income_uuid)
    table.insert(args, internal_user_id)

    db.query("UPDATE my_incomes SET " .. table.concat(updates, ", ")
        .. " WHERE uuid = ? AND user_id = ?", unpack(args))

    local refreshed = db.query("SELECT * FROM my_incomes WHERE uuid = ? LIMIT 1", income_uuid)[1]

    TaxAuditLogQueries.log({
        user_id = internal_user_id,
        user_email = user.email,
        entity_type = "MY_INCOME",
        entity_id = income_uuid,
        action = "UPDATE",
        old_values = cjson.encode(old),
        new_values = cjson.encode(refreshed),
    })

    refreshed.id = refreshed.uuid
    refreshed.user_id = nil
    return refreshed
end

-- ────────────────────────────────────────────────────────────────────────────
-- Soft delete (archive)
-- ────────────────────────────────────────────────────────────────────────────
function MyIncomeQueries.archive(income_uuid, user)
    local internal_user_id, err = resolveUserId(user)
    if not internal_user_id then return nil, err end

    local existing = db.query([[
        SELECT * FROM my_incomes WHERE uuid = ? AND user_id = ? LIMIT 1
    ]], income_uuid, internal_user_id)
    if not existing or #existing == 0 then return nil end

    db.query([[
        UPDATE my_incomes
           SET is_archived = true,
               archived_at = NOW(),
               archived_by = ?,
               updated_at  = NOW()
         WHERE uuid = ? AND user_id = ?
    ]], internal_user_id, income_uuid, internal_user_id)

    TaxAuditLogQueries.log({
        user_id = internal_user_id,
        user_email = user.email,
        entity_type = "MY_INCOME",
        entity_id = income_uuid,
        action = "DELETE",
        old_values = cjson.encode(existing[1]),
    })

    return true
end

return MyIncomeQueries
