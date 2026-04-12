--[[
    Hospital Ward Routes

    Endpoints:
    - GET    /api/v2/hospitals/:hospital_id/wards          - List wards
    - GET    /api/v2/hospitals/:hospital_id/wards/:id      - Get ward
    - POST   /api/v2/hospitals/:hospital_id/wards          - Create ward
    - PUT    /api/v2/hospitals/:hospital_id/wards/:id      - Update ward
    - DELETE /api/v2/hospitals/:hospital_id/wards/:id      - Delete ward
]]

local WardQueries = require "queries.WardQueries"
local AuthMiddleware = require("middleware.auth")
local RequestParser = require "helper.request_parser"
local db = require("lapis.db")

return function(app)
    local function error_response(status, message, details)
        ngx.log(ngx.ERR, "Wards API error: ", message)
        return { status = status, json = { error = message, details = type(details) == "string" and details or nil } }
    end

    local function resolve_hospital_id(hospital_uuid)
        local results = db.select("SELECT id FROM hospitals WHERE uuid = ? LIMIT 1", hospital_uuid)
        return results and results[1] and results[1].id or nil
    end

    app:get("/api/v2/hospitals/:hospital_id/wards", AuthMiddleware.requireAuth(function(self)
        local hospital_id = resolve_hospital_id(self.params.hospital_id)
        if not hospital_id then return error_response(404, "Hospital not found") end

        local params = self.params or {}
        params.hospital_id = hospital_id

        local ok, result = pcall(WardQueries.all, params)
        if not ok then return error_response(500, "Failed to list wards", tostring(result)) end

        return { status = 200, json = { data = result.data or {}, total = result.total or 0 } }
    end))

    app:post("/api/v2/hospitals/:hospital_id/wards", AuthMiddleware.requireAuth(function(self)
        local hospital_id = resolve_hospital_id(self.params.hospital_id)
        if not hospital_id then return error_response(404, "Hospital not found") end

        local params = RequestParser.parse_request(self)
        params.hospital_id = hospital_id

        local ok, ward = pcall(WardQueries.create, params)
        if not ok then return error_response(500, "Failed to create ward", tostring(ward)) end

        return { status = 201, json = { data = ward, message = "Ward created successfully" } }
    end))

    app:get("/api/v2/hospitals/:hospital_id/wards/:id", AuthMiddleware.requireAuth(function(self)
        local ok, ward = pcall(WardQueries.show, self.params.id)
        if not ok then return error_response(500, "Failed to fetch ward", tostring(ward)) end
        if not ward then return error_response(404, "Ward not found") end

        return { status = 200, json = { data = ward } }
    end))

    app:put("/api/v2/hospitals/:hospital_id/wards/:id", AuthMiddleware.requireAuth(function(self)
        local params = RequestParser.parse_request(self)

        local ok, result = pcall(WardQueries.update, self.params.id, params)
        if not ok then return error_response(500, "Failed to update ward", tostring(result)) end
        if not result then return error_response(404, "Ward not found") end

        return { status = 200, json = { data = result, message = "Ward updated successfully" } }
    end))

    app:delete("/api/v2/hospitals/:hospital_id/wards/:id", AuthMiddleware.requireAuth(function(self)
        local ok, result = pcall(WardQueries.destroy, self.params.id)
        if not ok then return error_response(500, "Failed to delete ward", tostring(result)) end
        if not result then return error_response(404, "Ward not found") end

        return { status = 200, json = { message = "Ward deleted successfully" } }
    end))
end
