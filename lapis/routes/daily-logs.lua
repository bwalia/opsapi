--[[
    Daily Log Routes (comprehensive daily tracking for care homes)

    Endpoints:
    - GET    /api/v2/patients/:patient_id/daily-logs          - List daily logs
    - GET    /api/v2/patients/:patient_id/daily-logs/today    - Get today's logs
    - GET    /api/v2/patients/:patient_id/daily-logs/:id      - Get daily log
    - POST   /api/v2/patients/:patient_id/daily-logs          - Create daily log
    - PUT    /api/v2/patients/:patient_id/daily-logs/:id      - Update daily log
    - DELETE /api/v2/patients/:patient_id/daily-logs/:id      - Delete daily log
]]

local DailyLogQueries = require "queries.DailyLogQueries"
local AuthMiddleware = require("middleware.auth")
local RequestParser = require "helper.request_parser"
local db = require("lapis.db")

return function(app)
    local function error_response(status, message, details)
        ngx.log(ngx.ERR, "Daily Logs API error: ", message)
        return { status = status, json = { error = message, details = type(details) == "string" and details or nil } }
    end

    local function resolve_patient_id(patient_uuid)
        local results = db.select("SELECT id FROM patients WHERE uuid = ? LIMIT 1", patient_uuid)
        return results and results[1] and results[1].id or nil
    end

    app:get("/api/v2/patients/:patient_id/daily-logs", AuthMiddleware.requireAuth(function(self)
        local patient_id = resolve_patient_id(self.params.patient_id)
        if not patient_id then return error_response(404, "Patient not found") end

        local params = self.params or {}
        params.patient_id = patient_id

        local ok, result = pcall(DailyLogQueries.all, params)
        if not ok then return error_response(500, "Failed to list daily logs", tostring(result)) end

        return { status = 200, json = { data = result.data or {}, total = result.total or 0 } }
    end))

    app:get("/api/v2/patients/:patient_id/daily-logs/today", AuthMiddleware.requireAuth(function(self)
        local patient_id = resolve_patient_id(self.params.patient_id)
        if not patient_id then return error_response(404, "Patient not found") end

        local ok, result = pcall(DailyLogQueries.getToday, patient_id)
        if not ok then return error_response(500, "Failed to fetch today's logs", tostring(result)) end

        return { status = 200, json = { data = result or {} } }
    end))

    app:get("/api/v2/patients/:patient_id/daily-logs/:id", AuthMiddleware.requireAuth(function(self)
        local ok, log = pcall(DailyLogQueries.show, self.params.id)
        if not ok then return error_response(500, "Failed to fetch daily log", tostring(log)) end
        if not log then return error_response(404, "Daily log not found") end

        return { status = 200, json = { data = log } }
    end))

    app:post("/api/v2/patients/:patient_id/daily-logs", AuthMiddleware.requireAuth(function(self)
        local patient_id = resolve_patient_id(self.params.patient_id)
        if not patient_id then return error_response(404, "Patient not found") end

        local params = RequestParser.parse_request(self)
        params.patient_id = patient_id
        if not params.recorded_by and self.current_user then
            params.recorded_by = self.current_user.uuid
        end

        local ok, log = pcall(DailyLogQueries.create, params)
        if not ok then return error_response(500, "Failed to create daily log", tostring(log)) end

        return { status = 201, json = { data = log, message = "Daily log created successfully" } }
    end))

    app:put("/api/v2/patients/:patient_id/daily-logs/:id", AuthMiddleware.requireAuth(function(self)
        local params = RequestParser.parse_request(self)

        local ok, result = pcall(DailyLogQueries.update, self.params.id, params)
        if not ok then return error_response(500, "Failed to update daily log", tostring(result)) end
        if not result then return error_response(404, "Daily log not found") end

        return { status = 200, json = { data = result, message = "Daily log updated successfully" } }
    end))

    app:delete("/api/v2/patients/:patient_id/daily-logs/:id", AuthMiddleware.requireAuth(function(self)
        local ok, result = pcall(DailyLogQueries.destroy, self.params.id)
        if not ok then return error_response(500, "Failed to delete daily log", tostring(result)) end
        if not result then return error_response(404, "Daily log not found") end

        return { status = 200, json = { message = "Daily log deleted successfully" } }
    end))
end
