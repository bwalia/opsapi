--[[
    Care Plan Routes

    Endpoints:
    - GET    /api/v2/patients/:patient_id/care-plans          - List care plans
    - GET    /api/v2/patients/:patient_id/care-plans/:id      - Get care plan
    - POST   /api/v2/patients/:patient_id/care-plans          - Create care plan
    - PUT    /api/v2/patients/:patient_id/care-plans/:id      - Update care plan
    - DELETE /api/v2/patients/:patient_id/care-plans/:id      - Delete care plan
    - GET    /api/v2/care-plans/due-for-review                - Get plans due for review
]]

local CarePlanQueries = require "queries.CarePlanQueries"
local AuthMiddleware = require("middleware.auth")
local RequestParser = require "helper.request_parser"
local db = require("lapis.db")

return function(app)
    local function error_response(status, message, details)
        ngx.log(ngx.ERR, "Care Plans API error: ", message)
        return { status = status, json = { error = message, details = type(details) == "string" and details or nil } }
    end

    local function resolve_patient(patient_uuid)
        local results = db.select("SELECT id, hospital_id FROM patients WHERE uuid = ? LIMIT 1", patient_uuid)
        return results and results[1] or nil
    end

    app:get("/api/v2/patients/:patient_id/care-plans", AuthMiddleware.requireAuth(function(self)
        local patient = resolve_patient(self.params.patient_id)
        if not patient then return error_response(404, "Patient not found") end

        local params = self.params or {}
        params.patient_id = patient.id

        local ok, result = pcall(CarePlanQueries.all, params)
        if not ok then return error_response(500, "Failed to list care plans", tostring(result)) end

        return { status = 200, json = { data = result.data or {}, total = result.total or 0 } }
    end))

    app:post("/api/v2/patients/:patient_id/care-plans", AuthMiddleware.requireAuth(function(self)
        local patient = resolve_patient(self.params.patient_id)
        if not patient then return error_response(404, "Patient not found") end

        local params = RequestParser.parse_request(self)
        params.patient_id = patient.id
        params.hospital_id = patient.hospital_id
        params.created_by = self.current_user and self.current_user.uuid or nil

        local ok, plan = pcall(CarePlanQueries.create, params)
        if not ok then return error_response(500, "Failed to create care plan", tostring(plan)) end

        return { status = 201, json = { data = plan, message = "Care plan created successfully" } }
    end))

    app:get("/api/v2/patients/:patient_id/care-plans/:id", AuthMiddleware.requireAuth(function(self)
        local ok, plan = pcall(CarePlanQueries.show, self.params.id)
        if not ok then return error_response(500, "Failed to fetch care plan", tostring(plan)) end
        if not plan then return error_response(404, "Care plan not found") end

        return { status = 200, json = { data = plan } }
    end))

    app:put("/api/v2/patients/:patient_id/care-plans/:id", AuthMiddleware.requireAuth(function(self)
        local params = RequestParser.parse_request(self)

        local ok, result = pcall(CarePlanQueries.update, self.params.id, params)
        if not ok then return error_response(500, "Failed to update care plan", tostring(result)) end
        if not result then return error_response(404, "Care plan not found") end

        return { status = 200, json = { data = result, message = "Care plan updated successfully" } }
    end))

    app:delete("/api/v2/patients/:patient_id/care-plans/:id", AuthMiddleware.requireAuth(function(self)
        local ok, result = pcall(CarePlanQueries.destroy, self.params.id)
        if not ok then return error_response(500, "Failed to delete care plan", tostring(result)) end
        if not result then return error_response(404, "Care plan not found") end

        return { status = 200, json = { message = "Care plan deleted successfully" } }
    end))

    -- Plans due for review (staff dashboard)
    app:get("/api/v2/care-plans/due-for-review", AuthMiddleware.requireAuth(function(self)
        local ok, result = pcall(CarePlanQueries.getDueForReview)
        if not ok then return error_response(500, "Failed to fetch review queue", tostring(result)) end

        return { status = 200, json = { data = result or {} } }
    end))
end
