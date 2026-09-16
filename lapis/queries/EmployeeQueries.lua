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
        fgas_certificate_no = e.fgas_certificate_no,
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

local TEXT_FIELDS = { "employee_code", "job_title", "phone", "email", "region", "fgas_certificate_no" }

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

-- A readable-but-strong temporary password: 14 chars, guaranteed upper/lower/digit
-- (meets the password policy), ambiguous characters (0/O/1/l/I) removed.
local function generate_temp_password()
    local sets = { "ABCDEFGHJKLMNPQRSTUVWXYZ", "abcdefghijkmnpqrstuvwxyz", "23456789" }
    local all = sets[1] .. sets[2] .. sets[3]
    math.randomseed((ngx and ngx.now and math.floor(ngx.now() * 1e6)) or os.time())
    local out = {}
    for _, s in ipairs(sets) do local i = math.random(#s); out[#out + 1] = s:sub(i, i) end
    for _ = 1, 11 do local i = math.random(#all); out[#out + 1] = all:sub(i, i) end
    for i = #out, 2, -1 do local j = math.random(i); out[i], out[j] = out[j], out[i] end
    return table.concat(out)
end

local TEAM_ROLES = { engineer = true, service_manager = true, telecaller = true }

--- One-step "add team member": provision a login + workspace membership + role
--- (+ an engineer profile) so a non-technical admin never touches the
--- user/member/role internals. Returns the temp password for the admin to hand
--- over (it is NOT emailed). Requires the caller to hold users.create.
-- @param data { first_name, last_name?, email, role_name, phone?, job_title?,
--   skills?, fgas_certificate_no?, hourly_cost_rate?, is_engineer? }
function EmployeeQueries.createTeamMember(namespace_id, actor_uuid, data)
    local first = nilify(data.first_name)
    local last = nilify(data.last_name)
    local email = nilify(data.email)
    local role_name = nilify(data.role_name)
    if not first then return nil, "First name is required" end
    if not email then return nil, "Email is required" end
    if not role_name or not TEAM_ROLES[role_name] then return nil, "Pick a role (engineer, service_manager or telecaller)" end

    if db.query("SELECT id FROM users WHERE LOWER(email) = LOWER(?) LIMIT 1", email)[1] then
        return nil, "Someone with this email already has a login"
    end
    local role = db.query("SELECT id FROM namespace_roles WHERE namespace_id = ? AND role_name = ? LIMIT 1",
        namespace_id, role_name)
    if not role[1] then return nil, "That role does not exist in this workspace" end

    -- Username is required + unique; derive a clean one from the email local part.
    local base = email:gsub("@.*$", ""):gsub("[^%w]", ""):lower()
    if #base < 3 then base = "user" .. base end
    base = base:sub(1, 20)
    local username, n = base, 0
    while db.query("SELECT id FROM users WHERE username = ? LIMIT 1", username)[1] do
        n = n + 1
        username = base:sub(1, 18) .. tostring(n)
    end

    local temp_password = generate_temp_password()
    local UserQueries = require("queries.UserQueries")
    -- Creates the login AND adds them to this workspace with the chosen role.
    local ok, user = pcall(UserQueries.create, {
        username = username, first_name = first, last_name = last, email = email,
        password = temp_password, active = true, role = "member",
        namespace_id = namespace_id, namespace_role = role_name,
    })
    if not ok or not user or not user.uuid then
        return nil, "Could not create the login: " .. tostring(user)
    end

    -- Engineer profile is optional detail; failing it must not undo the login.
    local is_engineer = to_bool(data.is_engineer, role_name == "engineer")
    local employee
    if is_engineer or nilify(data.job_title) or nilify(data.skills) or nilify(data.hourly_cost_rate) then
        employee = EmployeeQueries.createEmployee(namespace_id, actor_uuid, {
            user_uuid = user.uuid, is_engineer = is_engineer, is_active = true,
            job_title = data.job_title, phone = data.phone, region = data.region,
            skills = data.skills, fgas_certificate_no = data.fgas_certificate_no,
            hourly_cost_rate = data.hourly_cost_rate,
        })
    end

    local name = ((first or "") .. " " .. (last or "")):gsub("^%s+", ""):gsub("%s+$", "")
    return {
        user_uuid = user.uuid, email = email, name = name,
        role_name = role_name, temp_password = temp_password, employee = employee,
    }
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
