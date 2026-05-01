--[[
    Family Member Routes (Family & Caregiver Portal)

    Endpoints:
    - GET    /api/v2/patients/:patient_id/family-members              - List family members
    - GET    /api/v2/patients/:patient_id/family-members/next-of-kin  - Get next of kin
    - GET    /api/v2/patients/:patient_id/family-members/emergency    - Get emergency contacts
    - GET    /api/v2/patients/:patient_id/family-members/:id          - Get family member
    - POST   /api/v2/patients/:patient_id/family-members              - Add family member
    - PUT    /api/v2/patients/:patient_id/family-members/:id          - Update family member
    - DELETE /api/v2/patients/:patient_id/family-members/:id          - Remove family member
]]

local FamilyMemberQueries = require "queries.FamilyMemberQueries"
local AuthMiddleware = require("middleware.auth")
local RequestParser = require "helper.request_parser"
local db = require("lapis.db")

return function(app)
    local function error_response(status, message, details)
        ngx.log(ngx.ERR, "Family Members API error: ", message)
        return { status = status, json = { error = message, details = type(details) == "string" and details or nil } }
    end

    local function resolve_patient_id(patient_uuid)
        local results = db.select("SELECT id FROM patients WHERE uuid = ? LIMIT 1", patient_uuid)
        return results and results[1] and results[1].id or nil
    end

    app:get("/api/v2/patients/:patient_id/family-members", AuthMiddleware.requireAuth(function(self)
        local patient_id = resolve_patient_id(self.params.patient_id)
        if not patient_id then return error_response(404, "Patient not found") end

        local params = self.params or {}
        params.patient_id = patient_id

        local ok, result = pcall(FamilyMemberQueries.all, params)
        if not ok then return error_response(500, "Failed to list family members", tostring(result)) end

        return { status = 200, json = { data = result.data or {}, total = result.total or 0 } }
    end))

    app:get("/api/v2/patients/:patient_id/family-members/next-of-kin", AuthMiddleware.requireAuth(function(self)
        local patient_id = resolve_patient_id(self.params.patient_id)
        if not patient_id then return error_response(404, "Patient not found") end

        local ok, result = pcall(FamilyMemberQueries.getNextOfKin, patient_id)
        if not ok then return error_response(500, "Failed to fetch next of kin", tostring(result)) end

        return { status = 200, json = { data = result or {} } }
    end))

    app:get("/api/v2/patients/:patient_id/family-members/emergency", AuthMiddleware.requireAuth(function(self)
        local patient_id = resolve_patient_id(self.params.patient_id)
        if not patient_id then return error_response(404, "Patient not found") end

        local ok, result = pcall(FamilyMemberQueries.getEmergencyContacts, patient_id)
        if not ok then return error_response(500, "Failed to fetch emergency contacts", tostring(result)) end

        return { status = 200, json = { data = result or {} } }
    end))

    app:get("/api/v2/patients/:patient_id/family-members/:id", AuthMiddleware.requireAuth(function(self)
        local ok, member = pcall(FamilyMemberQueries.show, self.params.id)
        if not ok then return error_response(500, "Failed to fetch family member", tostring(member)) end
        if not member then return error_response(404, "Family member not found") end

        return { status = 200, json = { data = member } }
    end))

    app:post("/api/v2/patients/:patient_id/family-members", AuthMiddleware.requireAuth(function(self)
        local patient_id = resolve_patient_id(self.params.patient_id)
        if not patient_id then return error_response(404, "Patient not found") end

        local params = RequestParser.parse_request(self)
        params.patient_id = patient_id

        local ok, member = pcall(FamilyMemberQueries.create, params)
        if not ok then return error_response(500, "Failed to add family member", tostring(member)) end

        return { status = 201, json = { data = member, message = "Family member added successfully" } }
    end))

    app:put("/api/v2/patients/:patient_id/family-members/:id", AuthMiddleware.requireAuth(function(self)
        local params = RequestParser.parse_request(self)

        local ok, result = pcall(FamilyMemberQueries.update, self.params.id, params)
        if not ok then return error_response(500, "Failed to update family member", tostring(result)) end
        if not result then return error_response(404, "Family member not found") end

        return { status = 200, json = { data = result, message = "Family member updated successfully" } }
    end))

    app:delete("/api/v2/patients/:patient_id/family-members/:id", AuthMiddleware.requireAuth(function(self)
        local ok, result = pcall(FamilyMemberQueries.destroy, self.params.id)
        if not ok then return error_response(500, "Failed to remove family member", tostring(result)) end
        if not result then return error_response(404, "Family member not found") end

        return { status = 200, json = { message = "Family member removed successfully" } }
    end))
end
