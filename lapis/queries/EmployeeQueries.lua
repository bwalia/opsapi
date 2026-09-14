--[[
    Employee (staff directory) queries
    ==================================

    Enriches a users login with staff / engineer attributes, scoped to a tenant.
    An engineer is an active employee flagged is_engineer; assignment pickers list
    from here. The login itself lives in `users` (JWT auth) and is created via the
    normal invite flow — this profile links to an existing member by user_uuid.

    Introduced by field service; kept general (own model/queries/routes) so it can
    be reused. Reuses FieldServiceCommon for coercion + tenant-scoped resolution.
]]

local db = require("lapis.db")
local cjson = require("cjson")
local EmployeeModel = require("models.EmployeeModel")
local Common = require("queries.FieldServiceCommon")

local nilify, nullable, to_bool, to_number, arr = Common.nilify, Common.nullable, Common.to_bool, Common.to_number,
    Common.arr

local EmployeeQueries = {}

local EMPLOYEE_SELECT = [[
    SELECT e.*, u.email AS user_email, ]] .. Common.user_name_sql("u") .. [[ AS user_name
    FROM employees e
    LEFT JOIN users u ON u.uuid = e.user_uuid
]]

--- Normalise a skills value (array of strings, or comma-separated string) into a
--- clean array of trimmed non-empty strings.
local function normalise_skills(input)
    local list = input
    if type(input) == "string" then
        list = {}
        for part in tostring(input):gmatch("[^,]+") do table.insert(list, part) end
    end
    local out = {}
    for _, s in ipairs(type(list) == "table" and list or {}) do
        local v = tostring(s):match("^%s*(.-)%s*$")
        if v and v ~= "" then table.insert(out, v) end
    end
    return out
end

local function shape_employee(e)
    return {
        uuid = e.uuid,
        user_uuid = e.user_uuid,
        user_name = e.user_name,
        user_email = e.user_email,
        employee_code = e.employee_code,
        job_title = e.job_title,
        is_engineer = e.is_engineer,
        is_active = e.is_active,
        phone = e.phone,
        email = e.email,
        region = e.region,
        skills = arr(Common.decode(e.skills, {})),
        hourly_cost_rate = e.hourly_cost_rate,
        metadata = Common.decode(e.metadata, {}),
        created_at = e.created_at,
        updated_at = e.updated_at,
    }
end

function EmployeeQueries.listEmployees(namespace_id, params)
    params = params or {}
    local page, per_page, offset = Common.paging(params)
    local where = { "e.namespace_id = ?", "e.deleted_at IS NULL" }
    local values = { namespace_id }

    if params.is_engineer ~= nil and params.is_engineer ~= "" then
        table.insert(where, "e.is_engineer = ?")
        table.insert(values, to_bool(params.is_engineer, false))
    end
    if params.is_active ~= nil and params.is_active ~= "" then
        table.insert(where, "e.is_active = ?")
        table.insert(values, to_bool(params.is_active, true))
    end
    if nilify(params.search) then
        local term = "%" .. tostring(params.search) .. "%"
        table.insert(where,
            "(u.first_name ILIKE ? OR u.last_name ILIKE ? OR u.email ILIKE ? OR e.job_title ILIKE ? OR e.employee_code ILIKE ?)")
        for _ = 1, 5 do table.insert(values, term) end
    end
    local where_sql = table.concat(where, " AND ")

    local count = db.query([[
        SELECT COUNT(*) AS total FROM employees e LEFT JOIN users u ON u.uuid = e.user_uuid
        WHERE ]] .. where_sql, unpack(values))

    local page_values = { unpack(values) }
    table.insert(page_values, per_page)
    table.insert(page_values, offset)
    local rows = db.query(
        EMPLOYEE_SELECT .. " WHERE " .. where_sql .. " ORDER BY user_name ASC LIMIT ? OFFSET ?",
        unpack(page_values))

    local items = {}
    for _, e in ipairs(rows or {}) do table.insert(items, shape_employee(e)) end
    return { items = arr(items), meta = Common.meta(count[1].total, page, per_page) }
end

function EmployeeQueries.getEmployee(namespace_id, uuid)
    local rows = db.query(
        EMPLOYEE_SELECT .. " WHERE e.uuid = ? AND e.namespace_id = ? AND e.deleted_at IS NULL LIMIT 1",
        tostring(uuid), namespace_id)
    return rows and rows[1] and shape_employee(rows[1]) or nil
end

local TEXT_FIELDS = { "employee_code", "job_title", "phone", "email", "region" }

function EmployeeQueries.createEmployee(namespace_id, actor_uuid, data)
    local user_uuid = nilify(data.user_uuid)
    if not user_uuid then return nil, "user_uuid is required" end

    -- The login must already exist and be a member of this workspace.
    local u = db.query("SELECT uuid FROM users WHERE uuid = ? LIMIT 1", tostring(user_uuid))
    if not (u and u[1]) then return nil, "User not found" end
    if not Common.is_member(namespace_id, user_uuid) then
        return nil, "User is not a member of this workspace"
    end

    local existing = db.query([[
        SELECT id FROM employees WHERE namespace_id = ? AND user_uuid = ? AND deleted_at IS NULL LIMIT 1
    ]], namespace_id, tostring(user_uuid))
    if existing and existing[1] then return nil, "This user already has an employee profile" end

    local fields = {
        uuid = Common.uuid(),
        namespace_id = namespace_id,
        user_uuid = tostring(user_uuid),
        is_engineer = to_bool(data.is_engineer, false),
        is_active = to_bool(data.is_active, true),
        hourly_cost_rate = to_number(data.hourly_cost_rate),
        skills = Common.encode_array(normalise_skills(data.skills)),
        created_by_uuid = nilify(actor_uuid),
    }
    for _, f in ipairs(TEXT_FIELDS) do fields[f] = nilify(data[f]) end
    if type(data.metadata) == "table" then fields.metadata = cjson.encode(data.metadata) end

    local emp = EmployeeModel:create(fields)
    return EmployeeQueries.getEmployee(namespace_id, emp.uuid)
end

function EmployeeQueries.updateEmployee(namespace_id, uuid, data)
    local id = Common.resolve_id("employees", namespace_id, uuid)
    if not id then return nil, "Employee not found" end

    local update = {}
    for _, f in ipairs(TEXT_FIELDS) do
        if data[f] ~= nil then update[f] = nullable(data[f]) end
    end
    if data.is_engineer ~= nil then update.is_engineer = to_bool(data.is_engineer, false) end
    if data.is_active ~= nil then update.is_active = to_bool(data.is_active, true) end
    if data.hourly_cost_rate ~= nil then update.hourly_cost_rate = to_number(data.hourly_cost_rate) or db.NULL end
    if data.skills ~= nil then update.skills = Common.encode_array(normalise_skills(data.skills)) end
    if type(data.metadata) == "table" then update.metadata = cjson.encode(data.metadata) end
    if next(update) == nil then return nil, "No valid fields to update" end

    EmployeeModel:find(id):update(update)
    return EmployeeQueries.getEmployee(namespace_id, uuid)
end

function EmployeeQueries.deleteEmployee(namespace_id, uuid)
    local id = Common.resolve_id("employees", namespace_id, uuid)
    if not id then return nil, "Employee not found" end
    -- Removes the profile only; the users login is untouched.
    db.query("UPDATE employees SET deleted_at = NOW(), updated_at = NOW() WHERE id = ?", id)
    return true
end

return EmployeeQueries
