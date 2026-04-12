--[[
    Patient Access Control Routes (CORE FEATURE - Patient-Controlled Sharing)

    Enables patients to grant/revoke access to their medical data.
    GDPR and HIPAA compliant access control.

    Endpoints:
    - GET    /api/v2/patients/:patient_id/access-controls          - List access grants
    - GET    /api/v2/patients/:patient_id/access-controls/:id      - Get access grant
    - POST   /api/v2/patients/:patient_id/access-controls          - Grant access
    - PUT    /api/v2/patients/:patient_id/access-controls/:id      - Update access
    - DELETE /api/v2/patients/:patient_id/access-controls/:id      - Delete access grant
    - POST   /api/v2/patients/:patient_id/access-controls/:id/revoke - Revoke access
    - GET    /api/v2/access/verify                                  - Verify access by token
    - GET    /api/v2/access/my-patients                             - Get patients shared with me
]]

local PatientAccessControlQueries = require "queries.PatientAccessControlQueries"
local PatientAuditLogQueries = require "queries.PatientAuditLogQueries"
local AuthMiddleware = require("middleware.auth")
local RequestParser = require "helper.request_parser"
local db = require("lapis.db")

return function(app)
    local function error_response(status, message, details)
        ngx.log(ngx.ERR, "Access Control API error: ", message)
        return { status = status, json = { error = message, details = type(details) == "string" and details or nil } }
    end

    local function resolve_patient_id(patient_uuid)
        local results = db.select("SELECT id FROM patients WHERE uuid = ? LIMIT 1", patient_uuid)
        return results and results[1] and results[1].id or nil
    end

    -- LIST access grants for a patient
    app:get("/api/v2/patients/:patient_id/access-controls", AuthMiddleware.requireAuth(function(self)
        local patient_id = resolve_patient_id(self.params.patient_id)
        if not patient_id then return error_response(404, "Patient not found") end

        local params = self.params or {}
        params.patient_id = patient_id

        local ok, result = pcall(PatientAccessControlQueries.all, params)
        if not ok then return error_response(500, "Failed to list access controls", tostring(result)) end

        return { status = 200, json = { data = result.data or {}, total = result.total or 0 } }
    end))

    -- GRANT access
    app:post("/api/v2/patients/:patient_id/access-controls", AuthMiddleware.requireAuth(function(self)
        local patient_id = resolve_patient_id(self.params.patient_id)
        if not patient_id then return error_response(404, "Patient not found") end

        local params = RequestParser.parse_request(self)
        params.patient_id = patient_id
        params.granted_by = self.current_user and self.current_user.email or nil
        params.granted_by_user_id = self.current_user and self.current_user.id or nil

        if not params.granted_to then
            return error_response(400, "granted_to (email) is required")
        end
        if not params.role then
            return error_response(400, "role is required")
        end

        local ok, access = pcall(PatientAccessControlQueries.create, params)
        if not ok then return error_response(500, "Failed to grant access", tostring(access)) end

        -- Audit log
        pcall(PatientAuditLogQueries.log, {
            patient_id = patient_id,
            user_id = self.current_user and self.current_user.id or nil,
            action = "access_granted",
            resource_type = "access_control",
            resource_uuid = access and access.uuid or nil,
            ip_address = ngx.var.remote_addr,
            access_context = "direct"
        })

        return { status = 201, json = { data = access, message = "Access granted successfully" } }
    end))

    -- GET access grant
    app:get("/api/v2/patients/:patient_id/access-controls/:id", AuthMiddleware.requireAuth(function(self)
        local ok, access = pcall(PatientAccessControlQueries.show, self.params.id)
        if not ok then return error_response(500, "Failed to fetch access control", tostring(access)) end
        if not access then return error_response(404, "Access control not found") end

        return { status = 200, json = { data = access } }
    end))

    -- UPDATE access grant
    app:put("/api/v2/patients/:patient_id/access-controls/:id", AuthMiddleware.requireAuth(function(self)
        local params = RequestParser.parse_request(self)

        local ok, result = pcall(PatientAccessControlQueries.update, self.params.id, params)
        if not ok then return error_response(500, "Failed to update access control", tostring(result)) end
        if not result then return error_response(404, "Access control not found") end

        return { status = 200, json = { data = result, message = "Access control updated successfully" } }
    end))

    -- REVOKE access
    app:post("/api/v2/patients/:patient_id/access-controls/:id/revoke", AuthMiddleware.requireAuth(function(self)
        local params = RequestParser.parse_request(self)
        local reason = params.reason or "Revoked by patient"

        local record = PatientAccessControlQueries.show(self.params.id)
        if not record then return error_response(404, "Access control not found") end

        local ok, result = pcall(PatientAccessControlQueries.revoke, record.id, reason)
        if not ok then return error_response(500, "Failed to revoke access", tostring(result)) end

        -- Audit log
        pcall(PatientAuditLogQueries.log, {
            patient_id = record.patient_id,
            user_id = self.current_user and self.current_user.id or nil,
            action = "access_revoked",
            resource_type = "access_control",
            resource_uuid = record.uuid,
            ip_address = ngx.var.remote_addr,
            access_context = "direct"
        })

        return { status = 200, json = { message = "Access revoked successfully" } }
    end))

    -- DELETE access grant
    app:delete("/api/v2/patients/:patient_id/access-controls/:id", AuthMiddleware.requireAuth(function(self)
        local ok, result = pcall(PatientAccessControlQueries.destroy, self.params.id)
        if not ok then return error_response(500, "Failed to delete access control", tostring(result)) end
        if not result then return error_response(404, "Access control not found") end

        return { status = 200, json = { message = "Access control deleted successfully" } }
    end))

    -- VERIFY access by share token
    app:get("/api/v2/access/verify", AuthMiddleware.requireAuth(function(self)
        local token = self.params.token
        if not token then return error_response(400, "token parameter is required") end

        local ok, access = pcall(PatientAccessControlQueries.getByShareToken, token)
        if not ok then return error_response(500, "Failed to verify access", tostring(access)) end
        if not access then return error_response(403, "Invalid or expired access token") end

        -- Increment access count
        pcall(function()
            access:update({
                access_count = (access.access_count or 0) + 1,
                last_accessed_at = os.date("%Y-%m-%d %H:%M:%S")
            })
        end)

        return { status = 200, json = { data = access, valid = true } }
    end))

    -- GET patients shared with current user
    app:get("/api/v2/access/my-patients", AuthMiddleware.requireAuth(function(self)
        local email = self.current_user and self.current_user.email
        if not email then return error_response(400, "User email not available") end

        local ok, result = pcall(PatientAccessControlQueries.all, {
            granted_to = email,
            status = "active"
        })
        if not ok then return error_response(500, "Failed to fetch shared patients", tostring(result)) end

        return { status = 200, json = { data = result.data or {}, total = result.total or 0 } }
    end))
end
