local Model = require("lapis.db.model").Model
local cJson = require("cjson")
local Global = require "helper.global"

local CarePlanModel = Model:extend("care_plans", {
    timestamp = true,
    relations = {
        { "patient",   belongs_to = "PatientModel",   key = "patient_id" },
        { "hospital",  belongs_to = "HospitalModel",  key = "hospital_id" },
        { "care_logs", has_many = "CareLogModel",      key = "care_plan_id" },
        { "medications", has_many = "MedicationModel", key = "care_plan_id" }
    }
})

local JSON_FIELDS = {
    "goals", "interventions", "medication_schedule", "daily_routines",
    "risk_assessments", "dietary_requirements", "mobility_aids", "communication_needs"
}

function CarePlanModel:getByPatient(patient_id)
    return self:select("WHERE patient_id = ? ORDER BY created_at DESC", patient_id)
end

function CarePlanModel:getActive(patient_id)
    return self:select("WHERE patient_id = ? AND status = 'active' ORDER BY priority DESC, created_at DESC", patient_id)
end

function CarePlanModel:getDueForReview()
    return self:select("WHERE status = 'active' AND review_date <= CURRENT_DATE ORDER BY review_date ASC")
end

function CarePlanModel:getWithParsedData(id)
    local plan = self:find(id)
    if not plan then return nil end

    for _, field in ipairs(JSON_FIELDS) do
        if plan[field] then
            local ok, parsed = pcall(cJson.decode, plan[field])
            if ok then plan[field] = parsed end
        end
    end

    return plan
end

return CarePlanModel
