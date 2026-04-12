--[[
    Patient Audit Log Routes (GDPR/HIPAA Compliance)

    Read-only access to the audit trail. Audit logs are created automatically
    by other services.

    Endpoints:
    - GET    /api/v2/patients/:patient_id/audit-logs              - List audit logs
    - GET    /api/v2/patients/:patient_id/audit-logs/:id          - Get audit log entry
    - GET    /api/v2/patients/:patient_id/audit-logs/access-history - Access history
    - GET    /api/v2/patients/:patient_id/audit-logs/failed-access  - Failed access attempts
]]

local PatientAuditLogQueries = require "queries.PatientAuditLogQueries"
local AuthMiddleware = require("middleware.auth")
local db = require("lapis.db")

return function(app)
    local function error_response(status, message, details)
        ngx.log(ngx.ERR, "Audit Logs API error: ", message)
        return { status = status, json = { error = message, details = type(details) == "string" and details or nil } }
    end

    local function resolve_patient_id(patient_uuid)
        local results = db.select("SELECT id FROM patients WHERE uuid = ? LIMIT 1", patient_uuid)
        return results and results[1] and results[1].id or nil
    end

    -- List audit logs
    app:get("/api/v2/patients/:patient_id/audit-logs", AuthMiddleware.requireAuth(function(self)
        local patient_id = resolve_patient_id(self.params.patient_id)
        if not patient_id then return error_response(404, "Patient not found") end

        local params = self.params or {}
        params.patient_id = patient_id

        local ok, result = pcall(PatientAuditLogQueries.all, params)
        if not ok then return error_response(500, "Failed to list audit logs", tostring(result)) end

        -- Log this access to the audit trail itself
        pcall(PatientAuditLogQueries.log, {
            patient_id = patient_id,
            user_id = self.current_user and self.current_user.id or nil,
            action = "view",
            resource_type = "audit_log",
            ip_address = ngx.var.remote_addr,
            user_agent = ngx.var.http_user_agent,
            access_context = "direct"
        })

        return { status = 200, json = { data = result.data or {}, total = result.total or 0 } }
    end))

    -- Get single audit entry
    app:get("/api/v2/patients/:patient_id/audit-logs/:id", AuthMiddleware.requireAuth(function(self)
        local ok, entry = pcall(PatientAuditLogQueries.show, self.params.id)
        if not ok then return error_response(500, "Failed to fetch audit log entry", tostring(entry)) end
        if not entry then return error_response(404, "Audit log entry not found") end

        return { status = 200, json = { data = entry } }
    end))

    -- Access history (who viewed this patient's data)
    app:get("/api/v2/patients/:patient_id/audit-logs/access-history", AuthMiddleware.requireAuth(function(self)
        local patient_id = resolve_patient_id(self.params.patient_id)
        if not patient_id then return error_response(404, "Patient not found") end

        local ok, result = pcall(PatientAuditLogQueries.getAccessHistory, patient_id)
        if not ok then return error_response(500, "Failed to fetch access history", tostring(result)) end

        return { status = 200, json = { data = result or {} } }
    end))

    -- Failed access attempts
    app:get("/api/v2/patients/:patient_id/audit-logs/failed-access", AuthMiddleware.requireAuth(function(self)
        local patient_id = resolve_patient_id(self.params.patient_id)
        if not patient_id then return error_response(404, "Patient not found") end

        local ok, result = pcall(PatientAuditLogQueries.getFailedAccess, patient_id)
        if not ok then return error_response(500, "Failed to fetch failed access attempts", tostring(result)) end

        return { status = 200, json = { data = result or {} } }
    end))
end
