--[[
    Patient / Resident Routes (tenant-scoped)

    Endpoints:
    - GET    /api/v2/patients        - List (filters: hospital_id, status, first_name,
                                       last_name, room_number, search)
    - POST   /api/v2/patients        - Create (hospital_id must be in the caller's namespace)
    - GET    /api/v2/patients/:uuid  - Get
    - PUT    /api/v2/patients/:uuid  - Update
    - DELETE /api/v2/patients/:uuid  - Delete

    A patient's tenant is its hospital's namespace_id. Child resources
    (/api/v2/patients/:uuid/<care-plans|medications|...>) live in their own route
    files and are gated by routes/hospital-scope.lua.
]]

local db = require("lapis.db")
local cjson = require("cjson")
local AuthMiddleware = require("middleware.auth")
local NamespaceMiddleware = require("middleware.namespace")
local RequestParser = require("helper.request_parser")
local Global = require("helper.global")

local PERMISSION_MODULE = "hospital_patients"

local REQUIRED = { "hospital_id", "patient_id", "first_name", "last_name", "date_of_birth", "gender" }
local FIELDS = {
    "patient_id", "first_name", "last_name", "date_of_birth", "gender", "phone", "email",
    "address", "city", "state", "postal_code", "country", "emergency_contact_name",
    "emergency_contact_phone", "emergency_contact_relation", "blood_type", "allergies",
    "medical_conditions", "medications", "insurance_provider", "insurance_number",
    "admission_date", "discharge_date", "room_number", "bed_number", "status", "notes",
}
local REQUIRED_SET = {}
for _, f in ipairs(REQUIRED) do REQUIRED_SET[f] = true end
local SORTABLE = {
    first_name = true, last_name = true, patient_id = true, status = true,
    admission_date = true, room_number = true, created_at = true,
}

local function err(status, message)
    return { status = status, json = { success = false, error = message } }
end

local function guarded(action, handler)
    return AuthMiddleware.requireAuth(NamespaceMiddleware.requirePermission(PERMISSION_MODULE, action, handler))
end

local function blank(v)
    return v == nil or v == db.NULL or (type(v) == "string" and v:match("^%s*$") ~= nil)
end

-- Hospital (by numeric id or uuid) only if it belongs to the caller's namespace.
local function hospital_in_scope(self, ref)
    if blank(ref) then return nil end
    local rows = db.select("id, namespace_id FROM hospitals WHERE id::text = ? OR uuid = ? LIMIT 1",
        tostring(ref), tostring(ref))
    local h = rows and rows[1]
    if h and (self.is_platform_admin or h.namespace_id == self.namespace.id) then return h end
    return nil
end

local function find_in_scope(self, uuid)
    local rows = db.select([[
        p.*, h.uuid AS hospital_uuid, h.name AS hospital_name, h.namespace_id AS hospital_namespace_id
        FROM patients p JOIN hospitals h ON h.id = p.hospital_id
        WHERE p.uuid = ? LIMIT 1
    ]], uuid)
    local p = rows and rows[1]
    if not p then return nil end
    if not self.is_platform_admin and p.hospital_namespace_id ~= self.namespace.id then return nil end
    p.hospital_namespace_id = nil
    return p
end

-- Blank values are skipped on create and cleared on update (required columns never cleared).
local function collect(params, is_update)
    local data = {}
    for _, f in ipairs(FIELDS) do
        local v = params[f]
        if v ~= nil then
            if type(v) == "table" then v = cjson.encode(v) end
            if not blank(v) then
                data[f] = tostring(v)
            elseif is_update and not REQUIRED_SET[f] then
                data[f] = db.NULL
            end
        end
    end
    return data
end

local function write_error(e)
    local msg = tostring(e)
    if msg:find("invalid input syntax", 1, true) or msg:find("out of range", 1, true) then
        return err(400, "Invalid date or number in request")
    end
    ngx.log(ngx.ERR, "Patients API error: ", msg)
    return err(500, "Failed to save patient")
end

return function(app)
    app:get("/api/v2/patients", guarded("read", function(self)
        local p = self.params
        local where = { db.interpolate_query("h.namespace_id = ?", self.namespace.id) }
        if not blank(p.hospital_id) then
            where[#where + 1] = db.interpolate_query("(h.id::text = ? OR h.uuid = ?)",
                tostring(p.hospital_id), tostring(p.hospital_id))
        end
        for _, f in ipairs({ "status", "room_number" }) do
            if not blank(p[f]) then where[#where + 1] = db.interpolate_query("p." .. f .. " = ?", p[f]) end
        end
        for _, f in ipairs({ "first_name", "last_name" }) do
            if not blank(p[f]) then
                where[#where + 1] = db.interpolate_query("p." .. f .. " ILIKE ?", "%" .. p[f] .. "%")
            end
        end
        if not blank(p.search) then
            local like = "%" .. p.search .. "%"
            where[#where + 1] = db.interpolate_query(
                "(p.first_name ILIKE ? OR p.last_name ILIKE ? OR p.patient_id ILIKE ?" ..
                " OR (p.first_name || ' ' || p.last_name) ILIKE ?)", like, like, like, like)
        end
        local from_sql = " FROM patients p JOIN hospitals h ON h.id = p.hospital_id WHERE " ..
            table.concat(where, " AND ")

        local per_page = math.min(math.max(tonumber(p.perPage or p.per_page or p.limit) or 10, 1), 100)
        local page = math.max(tonumber(p.page) or 1, 1)
        local order_by = SORTABLE[p.orderBy or p.order_by] and (p.orderBy or p.order_by) or "last_name"
        local order_dir = tostring(p.orderDir or p.order_dir or "asc"):lower() == "desc" and "DESC" or "ASC"

        local total = db.query("SELECT COUNT(*) AS n" .. from_sql)[1].n
        local rows = db.query("SELECT p.*, h.uuid AS hospital_uuid, h.name AS hospital_name" .. from_sql ..
            " ORDER BY p." .. order_by .. " " .. order_dir .. ", p.id LIMIT ? OFFSET ?",
            per_page, (page - 1) * per_page)

        return { status = 200, json = { success = true, data = rows, total = tonumber(total) or 0,
            page = page, perPage = per_page } }
    end))

    app:post("/api/v2/patients", guarded("create", function(self)
        local params = RequestParser.parse_request(self)
        for _, f in ipairs(REQUIRED) do
            if blank(params[f]) then return err(400, "Missing required field: " .. f) end
        end
        local h = hospital_in_scope(self, params.hospital_id)
        if not h then return err(404, "Hospital not found") end

        local data = collect(params, false)
        data.uuid = Global.generateUUID()
        data.hospital_id = h.id
        data.status = data.status or "active"
        data.created_at = db.format_date()
        data.updated_at = data.created_at

        local ok, res = pcall(db.insert, "patients", data, db.raw("*"))
        if not ok then return write_error(res) end
        return { status = 201, json = { success = true, data = res[1], message = "Patient created successfully" } }
    end))

    app:get("/api/v2/patients/:uuid", guarded("read", function(self)
        local p = find_in_scope(self, self.params.uuid)
        if not p then return err(404, "Patient not found") end
        return { status = 200, json = { success = true, data = p } }
    end))

    app:put("/api/v2/patients/:uuid", guarded("update", function(self)
        local p = find_in_scope(self, self.params.uuid)
        if not p then return err(404, "Patient not found") end

        local params = RequestParser.parse_request(self)
        local data = collect(params, true)
        if not blank(params.hospital_id) then
            local h = hospital_in_scope(self, params.hospital_id)
            if not h then return err(404, "Hospital not found") end
            data.hospital_id = h.id
        end
        data.updated_at = db.format_date()

        local ok, res = pcall(db.update, "patients", data, { id = p.id }, db.raw("*"))
        if not ok then return write_error(res) end
        return { status = 200, json = { success = true, data = res[1], message = "Patient updated successfully" } }
    end))

    app:delete("/api/v2/patients/:uuid", guarded("delete", function(self)
        local p = find_in_scope(self, self.params.uuid)
        if not p then return err(404, "Patient not found") end

        local ok, res = pcall(db.delete, "patients", { id = p.id })
        if not ok then
            ngx.log(ngx.ERR, "Patients API delete error: ", tostring(res))
            return err(409, "Patient still has care records; discharge instead of deleting")
        end
        return { status = 200, json = { success = true, message = "Patient deleted successfully" } }
    end))
end
