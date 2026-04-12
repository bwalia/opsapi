--[[
    Hospital Department Routes

    API endpoints for hospital department management.

    Endpoints:
    - GET    /api/v2/hospitals/:hospital_id/departments          - List departments
    - GET    /api/v2/hospitals/:hospital_id/departments/:id      - Get department
    - POST   /api/v2/hospitals/:hospital_id/departments          - Create department
    - PUT    /api/v2/hospitals/:hospital_id/departments/:id      - Update department
    - DELETE /api/v2/hospitals/:hospital_id/departments/:id      - Delete department
]]

local respond_to = require("lapis.application").respond_to
local DepartmentQueries = require "queries.DepartmentQueries"
local AuthMiddleware = require("middleware.auth")
local RequestParser = require "helper.request_parser"
local db = require("lapis.db")

return function(app)
    local function error_response(status, message, details)
        ngx.log(ngx.ERR, "Departments API error: ", message)
        return { status = status, json = { error = message, details = type(details) == "string" and details or nil } }
    end

    local function resolve_hospital_id(hospital_uuid)
        local results = db.select("SELECT id FROM hospitals WHERE uuid = ? LIMIT 1", hospital_uuid)
        return results and results[1] and results[1].id or nil
    end

    -- LIST
    app:get("/api/v2/hospitals/:hospital_id/departments", AuthMiddleware.requireAuth(function(self)
        local hospital_id = resolve_hospital_id(self.params.hospital_id)
        if not hospital_id then return error_response(404, "Hospital not found") end

        local params = self.params or {}
        params.hospital_id = hospital_id

        local ok, result = pcall(DepartmentQueries.all, params)
        if not ok then return error_response(500, "Failed to list departments", tostring(result)) end

        return { status = 200, json = { data = result.data or {}, total = result.total or 0 } }
    end))

    -- CREATE
    app:post("/api/v2/hospitals/:hospital_id/departments", AuthMiddleware.requireAuth(function(self)
        local hospital_id = resolve_hospital_id(self.params.hospital_id)
        if not hospital_id then return error_response(404, "Hospital not found") end

        local params = RequestParser.parse_request(self)
        params.hospital_id = hospital_id

        local ok, dept = pcall(DepartmentQueries.create, params)
        if not ok then return error_response(500, "Failed to create department", tostring(dept)) end

        return { status = 201, json = { data = dept, message = "Department created successfully" } }
    end))

    -- GET
    app:get("/api/v2/hospitals/:hospital_id/departments/:id", AuthMiddleware.requireAuth(function(self)
        local ok, dept = pcall(DepartmentQueries.show, self.params.id)
        if not ok then return error_response(500, "Failed to fetch department", tostring(dept)) end
        if not dept then return error_response(404, "Department not found") end

        return { status = 200, json = { data = dept } }
    end))

    -- UPDATE
    app:put("/api/v2/hospitals/:hospital_id/departments/:id", AuthMiddleware.requireAuth(function(self)
        local params = RequestParser.parse_request(self)

        local ok, result = pcall(DepartmentQueries.update, self.params.id, params)
        if not ok then return error_response(500, "Failed to update department", tostring(result)) end
        if not result then return error_response(404, "Department not found") end

        return { status = 200, json = { data = result, message = "Department updated successfully" } }
    end))

    -- DELETE
    app:delete("/api/v2/hospitals/:hospital_id/departments/:id", AuthMiddleware.requireAuth(function(self)
        local ok, result = pcall(DepartmentQueries.destroy, self.params.id)
        if not ok then return error_response(500, "Failed to delete department", tostring(result)) end
        if not result then return error_response(404, "Department not found") end

        return { status = 200, json = { message = "Department deleted successfully" } }
    end))
end
