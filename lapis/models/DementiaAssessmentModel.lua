local Model = require("lapis.db.model").Model
local cJson = require("cjson")
local Global = require "helper.global"

local DementiaAssessmentModel = Model:extend("dementia_assessments", {
    timestamp = true,
    relations = {
        { "patient", belongs_to = "PatientModel", key = "patient_id" }
    }
})

local JSON_FIELDS = {
    "cognitive_domains", "behavioural_symptoms", "functional_abilities",
    "recognition_ability", "sleep_pattern", "recommendations",
    "memory_prompts", "routine_preferences", "triggers_to_avoid", "calming_strategies"
}

function DementiaAssessmentModel:getByPatient(patient_id)
    return self:select("WHERE patient_id = ? ORDER BY assessment_date DESC", patient_id)
end

function DementiaAssessmentModel:getLatest(patient_id)
    local results = self:select(
        "WHERE patient_id = ? AND status = 'completed' ORDER BY assessment_date DESC LIMIT 1",
        patient_id
    )
    return results and results[1] or nil
end

function DementiaAssessmentModel:getByType(patient_id, assessment_type)
    return self:select(
        "WHERE patient_id = ? AND assessment_type = ? ORDER BY assessment_date DESC",
        patient_id, assessment_type
    )
end

-- Tenant-scoped: only patients whose hospital is in namespace_id.
function DementiaAssessmentModel:getHighRiskWandering(namespace_id)
    return self:select(
        "WHERE patient_id IN (SELECT p.id FROM patients p JOIN hospitals h ON h.id = p.hospital_id WHERE h.namespace_id = ?) AND wandering_risk = 'high' AND status = 'completed' ORDER BY assessment_date DESC",
        namespace_id
    )
end

function DementiaAssessmentModel:getDueForReassessment(namespace_id)
    return self:select(
        "WHERE patient_id IN (SELECT p.id FROM patients p JOIN hospitals h ON h.id = p.hospital_id WHERE h.namespace_id = ?) AND next_assessment_date IS NOT NULL AND next_assessment_date <= CURRENT_DATE AND status = 'completed' ORDER BY next_assessment_date ASC",
        namespace_id
    )
end

function DementiaAssessmentModel:getWithParsedData(id)
    local assessment = self:find(id)
    if not assessment then return nil end

    for _, field in ipairs(JSON_FIELDS) do
        if assessment[field] then
            local ok, parsed = pcall(cJson.decode, assessment[field])
            if ok then assessment[field] = parsed end
        end
    end

    return assessment
end

return DementiaAssessmentModel
