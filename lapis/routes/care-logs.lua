--[[
    Care Log Routes (shift-based staff updates)

    Endpoints:
    - GET    /api/v2/patients/:patient_id/care-logs          - List care logs
    - GET    /api/v2/patients/:patient_id/care-logs/:id      - Get care log
    - POST   /api/v2/patients/:patient_id/care-logs          - Create care log
    - PUT    /api/v2/patients/:patient_id/care-logs/:id      - Update care log
    - DELETE /api/v2/patients/:patient_id/care-logs/:id      - Delete care log
    - GET    /api/v2/patients/:patient_id/care-logs/incidents - Get incident logs
]]

local CareLogQueries = require "queries.CareLogQueries"
local AuthMiddleware = require("middleware.auth")
local RequestParser = require "helper.request_parser"
local db = require("lapis.db")

return function(app)
    local function error_response(status, message, details)
        ngx.log(ngx.ERR, "Care Logs API error: ", message)
        return { status = status, json = { error = message, details = type(details) == "string" and details or nil } }
    end

    local function resolve_patient_id(patient_uuid)
        local results = db.select("SELECT id FROM patients WHERE uuid = ? LIMIT 1", patient_uuid)
        return results and results[1] and results[1].id or nil
    end

    app:get("/api/v2/patients/:patient_id/care-logs", AuthMiddleware.requireAuth(function(self)
        local patient_id = resolve_patient_id(self.params.patient_id)
        if not patient_id then return error_response(404, "Patient not found") end

        local params = self.params or {}
        params.patient_id = patient_id

        local ok, result = pcall(CareLogQueries.all, params)
        if not ok then return error_response(500, "Failed to list care logs", tostring(result)) end

        return { status = 200, json = { data = result.data or {}, total = result.total or 0 } }
    end))

    app:post("/api/v2/patients/:patient_id/care-logs", AuthMiddleware.requireAuth(function(self)
        local patient_id = resolve_patient_id(self.params.patient_id)
        if not patient_id then return error_response(404, "Patient not found") end

        local params = RequestParser.parse_request(self)
        params.patient_id = patient_id

        local ok, log = pcall(CareLogQueries.create, params)
        if not ok then return error_response(500, "Failed to create care log", tostring(log)) end

        return { status = 201, json = { data = log, message = "Care log created successfully" } }
    end))

    app:get("/api/v2/patients/:patient_id/care-logs/incidents", AuthMiddleware.requireAuth(function(self)
        local patient_id = resolve_patient_id(self.params.patient_id)
        if not patient_id then return error_response(404, "Patient not found") end

        local ok, result = pcall(CareLogQueries.getIncidents, patient_id)
        if not ok then return error_response(500, "Failed to fetch incidents", tostring(result)) end

        return { status = 200, json = { data = result or {} } }
    end))

    app:get("/api/v2/patients/:patient_id/care-logs/:id", AuthMiddleware.requireAuth(function(self)
        local ok, log = pcall(CareLogQueries.show, self.params.id)
        if not ok then return error_response(500, "Failed to fetch care log", tostring(log)) end
        if not log then return error_response(404, "Care log not found") end

        return { status = 200, json = { data = log } }
    end))

    app:put("/api/v2/patients/:patient_id/care-logs/:id", AuthMiddleware.requireAuth(function(self)
        local params = RequestParser.parse_request(self)

        local ok, result = pcall(CareLogQueries.update, self.params.id, params)
        if not ok then return error_response(500, "Failed to update care log", tostring(result)) end
        if not result then return error_response(404, "Care log not found") end

        return { status = 200, json = { data = result, message = "Care log updated successfully" } }
    end))

    app:delete("/api/v2/patients/:patient_id/care-logs/:id", AuthMiddleware.requireAuth(function(self)
        local ok, result = pcall(CareLogQueries.destroy, self.params.id)
        if not ok then return error_response(500, "Failed to delete care log", tostring(result)) end
        if not result then return error_response(404, "Care log not found") end

        return { status = 200, json = { message = "Care log deleted successfully" } }
    end))
end
