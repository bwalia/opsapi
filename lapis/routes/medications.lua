--[[
    Medication Routes

    Endpoints:
    - GET    /api/v2/patients/:patient_id/medications          - List medications
    - GET    /api/v2/patients/:patient_id/medications/active   - Get active medications
    - GET    /api/v2/patients/:patient_id/medications/prn      - Get PRN medications
    - GET    /api/v2/patients/:patient_id/medications/:id      - Get medication
    - POST   /api/v2/patients/:patient_id/medications          - Create medication
    - PUT    /api/v2/patients/:patient_id/medications/:id      - Update medication
    - DELETE /api/v2/patients/:patient_id/medications/:id      - Delete medication
]]

local MedicationQueries = require "queries.MedicationQueries"
local AuthMiddleware = require("middleware.auth")
local RequestParser = require "helper.request_parser"
local db = require("lapis.db")

return function(app)
    local function error_response(status, message, details)
        ngx.log(ngx.ERR, "Medications API error: ", message)
        return { status = status, json = { error = message, details = type(details) == "string" and details or nil } }
    end

    local function resolve_patient_id(patient_uuid)
        local results = db.select("SELECT id FROM patients WHERE uuid = ? LIMIT 1", patient_uuid)
        return results and results[1] and results[1].id or nil
    end

    app:get("/api/v2/patients/:patient_id/medications", AuthMiddleware.requireAuth(function(self)
        local patient_id = resolve_patient_id(self.params.patient_id)
        if not patient_id then return error_response(404, "Patient not found") end

        local params = self.params or {}
        params.patient_id = patient_id

        local ok, result = pcall(MedicationQueries.all, params)
        if not ok then return error_response(500, "Failed to list medications", tostring(result)) end

        return { status = 200, json = { data = result.data or {}, total = result.total or 0 } }
    end))

    app:get("/api/v2/patients/:patient_id/medications/active", AuthMiddleware.requireAuth(function(self)
        local patient_id = resolve_patient_id(self.params.patient_id)
        if not patient_id then return error_response(404, "Patient not found") end

        local ok, result = pcall(MedicationQueries.getActive, patient_id)
        if not ok then return error_response(500, "Failed to fetch active medications", tostring(result)) end

        return { status = 200, json = { data = result or {} } }
    end))

    app:get("/api/v2/patients/:patient_id/medications/prn", AuthMiddleware.requireAuth(function(self)
        local patient_id = resolve_patient_id(self.params.patient_id)
        if not patient_id then return error_response(404, "Patient not found") end

        local ok, result = pcall(MedicationQueries.getPRN, patient_id)
        if not ok then return error_response(500, "Failed to fetch PRN medications", tostring(result)) end

        return { status = 200, json = { data = result or {} } }
    end))

    app:get("/api/v2/patients/:patient_id/medications/:id", AuthMiddleware.requireAuth(function(self)
        local ok, med = pcall(MedicationQueries.show, self.params.id)
        if not ok then return error_response(500, "Failed to fetch medication", tostring(med)) end
        if not med then return error_response(404, "Medication not found") end

        return { status = 200, json = { data = med } }
    end))

    app:post("/api/v2/patients/:patient_id/medications", AuthMiddleware.requireAuth(function(self)
        local patient_id = resolve_patient_id(self.params.patient_id)
        if not patient_id then return error_response(404, "Patient not found") end

        local params = RequestParser.parse_request(self)
        params.patient_id = patient_id

        local ok, med = pcall(MedicationQueries.create, params)
        if not ok then return error_response(500, "Failed to create medication", tostring(med)) end

        return { status = 201, json = { data = med, message = "Medication created successfully" } }
    end))

    app:put("/api/v2/patients/:patient_id/medications/:id", AuthMiddleware.requireAuth(function(self)
        local params = RequestParser.parse_request(self)

        local ok, result = pcall(MedicationQueries.update, self.params.id, params)
        if not ok then return error_response(500, "Failed to update medication", tostring(result)) end
        if not result then return error_response(404, "Medication not found") end

        return { status = 200, json = { data = result, message = "Medication updated successfully" } }
    end))

    app:delete("/api/v2/patients/:patient_id/medications/:id", AuthMiddleware.requireAuth(function(self)
        local ok, result = pcall(MedicationQueries.destroy, self.params.id)
        if not ok then return error_response(500, "Failed to delete medication", tostring(result)) end
        if not result then return error_response(404, "Medication not found") end

        return { status = 200, json = { message = "Medication deleted successfully" } }
    end))
end
