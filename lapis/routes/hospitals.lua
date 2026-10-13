--[[
    Hospital / Care Home Routes (tenant-scoped)

    Endpoints:
    - GET    /api/v2/hospitals                  - List (filters: type, status, city, search)
    - POST   /api/v2/hospitals                  - Create
    - GET    /api/v2/hospitals/:uuid            - Get
    - PUT    /api/v2/hospitals/:uuid            - Update
    - DELETE /api/v2/hospitals/:uuid            - Delete
    - GET    /api/v2/hospitals/:uuid/statistics - Patient / occupancy counts

    hospitals.namespace_id is the tenant anchor (see routes/hospital-scope.lua).
    Lists only ever show the caller's namespace; a single hospital outside it is
    a 404 (platform admins excepted, matching hospital-scope).
]]

local db = require("lapis.db")
local AuthMiddleware = require("middleware.auth")
local NamespaceMiddleware = require("middleware.namespace")
local RequestParser = require("helper.request_parser")
local Global = require("helper.global")

local PERMISSION_MODULE = "hospital_patients"

local REQUIRED = { "name", "license_number" }
local TEXT_FIELDS = {
    "name", "type", "license_number", "address", "city", "state", "postal_code", "country",
    "phone", "email", "website", "specialties", "services", "facilities", "operating_hours",
    "contact_person", "contact_phone", "status",
}
local SORTABLE = { name = true, type = true, city = true, status = true, capacity = true, created_at = true }

local function err(status, message)
    return { status = status, json = { success = false, error = message } }
end

local function guarded(action, handler)
    return AuthMiddleware.requireAuth(NamespaceMiddleware.requirePermission(PERMISSION_MODULE, action, handler))
end

local function blank(v)
    return v == nil or v == db.NULL or (type(v) == "string" and v:match("^%s*$") ~= nil)
end

local function to_bool(v)
    if type(v) == "boolean" then return v end
    v = tostring(v):lower()
    return v == "true" or v == "1" or v == "on" or v == "yes"
end

-- Whitelisted columns from the (form or JSON) body. Blank values are skipped on
-- create and cleared on update (except required columns, which are never cleared).
local function collect(params, is_update)
    local data = {}
    for _, f in ipairs(TEXT_FIELDS) do
        local v = params[f]
        if v ~= nil then
            if type(v) == "table" then v = require("cjson").encode(v) end
            if not blank(v) then
                data[f] = tostring(v)
            elseif is_update and f ~= "name" and f ~= "license_number" then
                data[f] = db.NULL
            end
        end
    end
    if params.capacity ~= nil then
        data.capacity = tonumber(params.capacity) or 0
    end
    if params.emergency_services ~= nil then
        data.emergency_services = to_bool(params.emergency_services)
    end
    return data
end

-- Unique license_number is global; surface the clash instead of a 500.
local function write_error(e)
    local msg = tostring(e)
    if msg:find("duplicate key", 1, true) then
        return err(409, "A hospital with this license number already exists")
    end
    ngx.log(ngx.ERR, "Hospitals API error: ", msg)
    return err(500, "Failed to save hospital")
end

local function find_in_scope(self, uuid)
    local rows = db.select("* FROM hospitals WHERE uuid = ? LIMIT 1", uuid)
    local h = rows and rows[1]
    if not h then return nil end
    if self.is_platform_admin or h.namespace_id == self.namespace.id then return h end
    return nil
end

return function(app)
    app:get("/api/v2/hospitals", guarded("read", function(self)
        local p = self.params
        local where = { db.interpolate_query("namespace_id = ?", self.namespace.id) }
        for _, f in ipairs({ "type", "status", "city" }) do
            if not blank(p[f]) then where[#where + 1] = db.interpolate_query(f .. " = ?", p[f]) end
        end
        if not blank(p.search) then
            local like = "%" .. p.search .. "%"
            where[#where + 1] = db.interpolate_query(
                "(name ILIKE ? OR city ILIKE ? OR license_number ILIKE ?)", like, like, like)
        end
        local where_sql = table.concat(where, " AND ")

        local per_page = math.min(math.max(tonumber(p.perPage or p.per_page or p.limit) or 10, 1), 100)
        local page = math.max(tonumber(p.page) or 1, 1)
        local order_by = SORTABLE[p.orderBy or p.order_by] and (p.orderBy or p.order_by) or "name"
        local order_dir = tostring(p.orderDir or p.order_dir or "asc"):lower() == "desc" and "DESC" or "ASC"

        local total = db.select("COUNT(*) AS n FROM hospitals WHERE " .. where_sql)[1].n
        local rows = db.select("* FROM hospitals WHERE " .. where_sql ..
            " ORDER BY " .. order_by .. " " .. order_dir .. ", id LIMIT ? OFFSET ?",
            per_page, (page - 1) * per_page)

        return { status = 200, json = { success = true, data = rows, total = tonumber(total) or 0,
            page = page, perPage = per_page } }
    end))

    app:post("/api/v2/hospitals", guarded("create", function(self)
        local params = RequestParser.parse_request(self)
        for _, f in ipairs(REQUIRED) do
            if blank(params[f]) then return err(400, "Missing required field: " .. f) end
        end
        local data = collect(params, false)
        data.uuid = Global.generateUUID()
        data.type = data.type or "hospital"
        data.status = data.status or "active"
        data.namespace_id = self.namespace.id
        data.created_at = db.format_date()
        data.updated_at = data.created_at

        local ok, res = pcall(db.insert, "hospitals", data, db.raw("*"))
        if not ok then return write_error(res) end
        return { status = 201, json = { success = true, data = res[1], message = "Hospital created successfully" } }
    end))

    -- Registered before /:uuid so "statistics" is not taken as a uuid.
    app:get("/api/v2/hospitals/:uuid/statistics", guarded("read", function(self)
        local h = find_in_scope(self, self.params.uuid)
        if not h then return err(404, "Hospital not found") end

        local s = db.query([[
            SELECT COUNT(*) AS total_patients,
                   COUNT(*) FILTER (WHERE status = 'active') AS active_patients,
                   COUNT(*) FILTER (WHERE status = 'discharged') AS discharged_patients,
                   COUNT(*) FILTER (WHERE admission_date >= CURRENT_DATE - INTERVAL '30 days') AS admissions_last_30_days
            FROM patients WHERE hospital_id = ?
        ]], h.id)[1]
        local capacity = tonumber(h.capacity) or 0
        local active = tonumber(s.active_patients) or 0
        local stats = {
            capacity = capacity,
            total_patients = tonumber(s.total_patients) or 0,
            active_patients = active,
            discharged_patients = tonumber(s.discharged_patients) or 0,
            admissions_last_30_days = tonumber(s.admissions_last_30_days) or 0,
            available_beds = math.max(capacity - active, 0),
            occupancy_rate = capacity > 0 and math.floor(active * 1000 / capacity) / 10 or 0,
        }
        return { status = 200, json = { success = true, data = stats } }
    end))

    app:get("/api/v2/hospitals/:uuid", guarded("read", function(self)
        local h = find_in_scope(self, self.params.uuid)
        if not h then return err(404, "Hospital not found") end
        return { status = 200, json = { success = true, data = h } }
    end))

    app:put("/api/v2/hospitals/:uuid", guarded("update", function(self)
        local h = find_in_scope(self, self.params.uuid)
        if not h then return err(404, "Hospital not found") end

        local data = collect(RequestParser.parse_request(self), true)
        data.updated_at = db.format_date()
        local ok, res = pcall(db.update, "hospitals", data, { id = h.id }, db.raw("*"))
        if not ok then return write_error(res) end
        return { status = 200, json = { success = true, data = res[1], message = "Hospital updated successfully" } }
    end))

    app:delete("/api/v2/hospitals/:uuid", guarded("delete", function(self)
        local h = find_in_scope(self, self.params.uuid)
        if not h then return err(404, "Hospital not found") end

        local n = db.select("COUNT(*) AS n FROM patients WHERE hospital_id = ?", h.id)[1].n
        if (tonumber(n) or 0) > 0 then
            return err(409, "Hospital still has patients; move or delete them first")
        end
        local ok, res = pcall(db.delete, "hospitals", { id = h.id })
        if not ok then
            ngx.log(ngx.ERR, "Hospitals API delete error: ", tostring(res))
            return err(409, "Hospital is still referenced by other records")
        end
        return { status = 200, json = { success = true, message = "Hospital deleted successfully" } }
    end))
end
