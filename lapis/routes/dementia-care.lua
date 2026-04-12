--[[
    Dementia & Elderly Care Routes

    Specialised endpoints for dementia assessment and elderly care management.

    Endpoints:
    - GET    /api/v2/patients/:patient_id/dementia-assessments          - List assessments
    - GET    /api/v2/patients/:patient_id/dementia-assessments/latest   - Get latest assessment
    - GET    /api/v2/patients/:patient_id/dementia-assessments/:id      - Get assessment
    - POST   /api/v2/patients/:patient_id/dementia-assessments          - Create assessment
    - PUT    /api/v2/patients/:patient_id/dementia-assessments/:id      - Update assessment
    - DELETE /api/v2/patients/:patient_id/dementia-assessments/:id      - Delete assessment
    - GET    /api/v2/dementia/high-risk-wandering                       - High wandering risk patients
    - GET    /api/v2/dementia/due-for-reassessment                      - Patients due for reassessment
]]

local DementiaAssessmentQueries = require "queries.DementiaAssessmentQueries"
local AuthMiddleware = require("middleware.auth")
local RequestParser = require "helper.request_parser"
local db = require("lapis.db")

return function(app)
    local function error_response(status, message, details)
        ngx.log(ngx.ERR, "Dementia Care API error: ", message)
        return { status = status, json = { error = message, details = type(details) == "string" and details or nil } }
    end

    local function resolve_patient_id(patient_uuid)
        local results = db.select("SELECT id FROM patients WHERE uuid = ? LIMIT 1", patient_uuid)
        return results and results[1] and results[1].id or nil
    end

    app:get("/api/v2/patients/:patient_id/dementia-assessments", AuthMiddleware.requireAuth(function(self)
        local patient_id = resolve_patient_id(self.params.patient_id)
        if not patient_id then return error_response(404, "Patient not found") end

        local params = self.params or {}
        params.patient_id = patient_id

        local ok, result = pcall(DementiaAssessmentQueries.all, params)
        if not ok then return error_response(500, "Failed to list assessments", tostring(result)) end

        return { status = 200, json = { data = result.data or {}, total = result.total or 0 } }
    end))

    app:get("/api/v2/patients/:patient_id/dementia-assessments/latest", AuthMiddleware.requireAuth(function(self)
        local patient_id = resolve_patient_id(self.params.patient_id)
        if not patient_id then return error_response(404, "Patient not found") end

        local ok, result = pcall(DementiaAssessmentQueries.getLatest, patient_id)
        if not ok then return error_response(500, "Failed to fetch latest assessment", tostring(result)) end

        return { status = 200, json = { data = result } }
    end))

    app:get("/api/v2/patients/:patient_id/dementia-assessments/:id", AuthMiddleware.requireAuth(function(self)
        local ok, assessment = pcall(DementiaAssessmentQueries.show, self.params.id)
        if not ok then return error_response(500, "Failed to fetch assessment", tostring(assessment)) end
        if not assessment then return error_response(404, "Assessment not found") end

        return { status = 200, json = { data = assessment } }
    end))

    app:post("/api/v2/patients/:patient_id/dementia-assessments", AuthMiddleware.requireAuth(function(self)
        local patient_id = resolve_patient_id(self.params.patient_id)
        if not patient_id then return error_response(404, "Patient not found") end

        local params = RequestParser.parse_request(self)
        params.patient_id = patient_id

        local ok, assessment = pcall(DementiaAssessmentQueries.create, params)
        if not ok then return error_response(500, "Failed to create assessment", tostring(assessment)) end

        return { status = 201, json = { data = assessment, message = "Assessment created successfully" } }
    end))

    app:put("/api/v2/patients/:patient_id/dementia-assessments/:id", AuthMiddleware.requireAuth(function(self)
        local params = RequestParser.parse_request(self)

        local ok, result = pcall(DementiaAssessmentQueries.update, self.params.id, params)
        if not ok then return error_response(500, "Failed to update assessment", tostring(result)) end
        if not result then return error_response(404, "Assessment not found") end

        return { status = 200, json = { data = result, message = "Assessment updated successfully" } }
    end))

    app:delete("/api/v2/patients/:patient_id/dementia-assessments/:id", AuthMiddleware.requireAuth(function(self)
        local ok, result = pcall(DementiaAssessmentQueries.destroy, self.params.id)
        if not ok then return error_response(500, "Failed to delete assessment", tostring(result)) end
        if not result then return error_response(404, "Assessment not found") end

        return { status = 200, json = { message = "Assessment deleted successfully" } }
    end))

    -- Dashboard: high wandering risk
    app:get("/api/v2/dementia/high-risk-wandering", AuthMiddleware.requireAuth(function(self)
        local ok, result = pcall(DementiaAssessmentQueries.getHighRiskWandering)
        if not ok then return error_response(500, "Failed to fetch high-risk patients", tostring(result)) end

        return { status = 200, json = { data = result or {} } }
    end))

    -- Dashboard: due for reassessment
    app:get("/api/v2/dementia/due-for-reassessment", AuthMiddleware.requireAuth(function(self)
        local ok, result = pcall(DementiaAssessmentQueries.getDueForReassessment)
        if not ok then return error_response(500, "Failed to fetch reassessment queue", tostring(result)) end

        return { status = 200, json = { data = result or {} } }
    end))
end
