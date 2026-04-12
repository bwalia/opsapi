local Model = require("lapis.db.model").Model
local cJson = require("cjson")
local Global = require "helper.global"

local MedicationModel = Model:extend("medications", {
    timestamp = true,
    relations = {
        { "patient",   belongs_to = "PatientModel",  key = "patient_id" },
        { "care_plan", belongs_to = "CarePlanModel",  key = "care_plan_id" }
    }
})

local JSON_FIELDS = { "schedule_times", "side_effects", "interactions" }

function MedicationModel:getByPatient(patient_id)
    return self:select("WHERE patient_id = ? ORDER BY name ASC", patient_id)
end

function MedicationModel:getActive(patient_id)
    return self:select("WHERE patient_id = ? AND status = 'active' ORDER BY name ASC", patient_id)
end

function MedicationModel:getPRN(patient_id)
    return self:select("WHERE patient_id = ? AND status = 'active' AND is_prn = true ORDER BY name ASC", patient_id)
end

function MedicationModel:getWithParsedData(id)
    local med = self:find(id)
    if not med then return nil end

    for _, field in ipairs(JSON_FIELDS) do
        if med[field] then
            local ok, parsed = pcall(cJson.decode, med[field])
            if ok then med[field] = parsed end
        end
    end

    return med
end

return MedicationModel
