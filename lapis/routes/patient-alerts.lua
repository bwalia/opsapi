--[[
    Patient Alert Routes

    Endpoints:
    - GET    /api/v2/patients/:patient_id/alerts              - List patient alerts
    - POST   /api/v2/patients/:patient_id/alerts              - Create alert
    - GET    /api/v2/patients/:patient_id/alerts/:id          - Get alert
    - PUT    /api/v2/patients/:patient_id/alerts/:id          - Update alert
    - POST   /api/v2/patients/:patient_id/alerts/:id/acknowledge - Acknowledge alert
    - POST   /api/v2/patients/:patient_id/alerts/:id/resolve    - Resolve alert
    - DELETE /api/v2/patients/:patient_id/alerts/:id          - Delete alert
    - GET    /api/v2/hospitals/:hospital_id/alerts/active      - Active hospital alerts
    - GET    /api/v2/hospitals/:hospital_id/alerts/critical    - Critical hospital alerts
]]

local PatientAlertQueries = require "queries.PatientAlertQueries"
local AuthMiddleware = require("middleware.auth")
local RequestParser = require "helper.request_parser"
local db = require("lapis.db")

return function(app)
    local function error_response(status, message, details)
        ngx.log(ngx.ERR, "Alerts API error: ", message)
        return { status = status, json = { error = message, details = type(details) == "string" and details or nil } }
    end

    local function resolve_patient(patient_uuid)
        local results = db.select("SELECT id, hospital_id FROM patients WHERE uuid = ? LIMIT 1", patient_uuid)
        return results and results[1] or nil
    end

    local function resolve_hospital_id(hospital_uuid)
        local results = db.select("SELECT id FROM hospitals WHERE uuid = ? LIMIT 1", hospital_uuid)
        return results and results[1] and results[1].id or nil
    end

    -- List alerts for a patient
    app:get("/api/v2/patients/:patient_id/alerts", AuthMiddleware.requireAuth(function(self)
        local patient = resolve_patient(self.params.patient_id)
        if not patient then return error_response(404, "Patient not found") end

        local params = self.params or {}
        params.patient_id = patient.id

        local ok, result = pcall(PatientAlertQueries.all, params)
        if not ok then return error_response(500, "Failed to list alerts", tostring(result)) end

        return { status = 200, json = { data = result.data or {}, total = result.total or 0 } }
    end))

    -- Create alert
    app:post("/api/v2/patients/:patient_id/alerts", AuthMiddleware.requireAuth(function(self)
        local patient = resolve_patient(self.params.patient_id)
        if not patient then return error_response(404, "Patient not found") end

        local params = RequestParser.parse_request(self)
        params.patient_id = patient.id
        params.hospital_id = patient.hospital_id
        params.triggered_by = self.current_user and self.current_user.uuid or "system"

        local ok, alert = pcall(PatientAlertQueries.create, params)
        if not ok then return error_response(500, "Failed to create alert", tostring(alert)) end

        return { status = 201, json = { data = alert, message = "Alert created successfully" } }
    end))

    -- Get alert
    app:get("/api/v2/patients/:patient_id/alerts/:id", AuthMiddleware.requireAuth(function(self)
        local ok, alert = pcall(PatientAlertQueries.show, self.params.id)
        if not ok then return error_response(500, "Failed to fetch alert", tostring(alert)) end
        if not alert then return error_response(404, "Alert not found") end

        return { status = 200, json = { data = alert } }
    end))

    -- Update alert
    app:put("/api/v2/patients/:patient_id/alerts/:id", AuthMiddleware.requireAuth(function(self)
        local params = RequestParser.parse_request(self)

        local ok, result = pcall(PatientAlertQueries.update, self.params.id, params)
        if not ok then return error_response(500, "Failed to update alert", tostring(result)) end
        if not result then return error_response(404, "Alert not found") end

        return { status = 200, json = { data = result, message = "Alert updated successfully" } }
    end))

    -- Acknowledge alert
    app:post("/api/v2/patients/:patient_id/alerts/:id/acknowledge", AuthMiddleware.requireAuth(function(self)
        local acknowledged_by = self.current_user and self.current_user.uuid or "unknown"

        local ok, result = pcall(PatientAlertQueries.acknowledge, self.params.id, acknowledged_by)
        if not ok then return error_response(500, "Failed to acknowledge alert", tostring(result)) end
        if not result then return error_response(404, "Alert not found") end

        return { status = 200, json = { data = result, message = "Alert acknowledged" } }
    end))

    -- Resolve alert
    app:post("/api/v2/patients/:patient_id/alerts/:id/resolve", AuthMiddleware.requireAuth(function(self)
        local params = RequestParser.parse_request(self)
        local resolved_by = self.current_user and self.current_user.uuid or "unknown"
        local notes = params.resolution_notes or params.notes

        local ok, result = pcall(PatientAlertQueries.resolve, self.params.id, resolved_by, notes)
        if not ok then return error_response(500, "Failed to resolve alert", tostring(result)) end
        if not result then return error_response(404, "Alert not found") end

        return { status = 200, json = { data = result, message = "Alert resolved" } }
    end))

    -- Delete alert
    app:delete("/api/v2/patients/:patient_id/alerts/:id", AuthMiddleware.requireAuth(function(self)
        local ok, result = pcall(PatientAlertQueries.destroy, self.params.id)
        if not ok then return error_response(500, "Failed to delete alert", tostring(result)) end
        if not result then return error_response(404, "Alert not found") end

        return { status = 200, json = { message = "Alert deleted successfully" } }
    end))

    -- Hospital-level: active alerts
    app:get("/api/v2/hospitals/:hospital_id/alerts/active", AuthMiddleware.requireAuth(function(self)
        local hospital_id = resolve_hospital_id(self.params.hospital_id)
        if not hospital_id then return error_response(404, "Hospital not found") end

        local ok, result = pcall(PatientAlertQueries.getActive, hospital_id)
        if not ok then return error_response(500, "Failed to fetch active alerts", tostring(result)) end

        return { status = 200, json = { data = result or {} } }
    end))

    -- Hospital-level: critical alerts
    app:get("/api/v2/hospitals/:hospital_id/alerts/critical", AuthMiddleware.requireAuth(function(self)
        local hospital_id = resolve_hospital_id(self.params.hospital_id)
        if not hospital_id then return error_response(404, "Hospital not found") end

        local ok, result = pcall(PatientAlertQueries.getCritical, hospital_id)
        if not ok then return error_response(500, "Failed to fetch critical alerts", tostring(result)) end

        return { status = 200, json = { data = result or {} } }
    end))
end
