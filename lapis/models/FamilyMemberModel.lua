local Model = require("lapis.db.model").Model
local cJson = require("cjson")
local Global = require "helper.global"

local FamilyMemberModel = Model:extend("family_members", {
    timestamp = true,
    relations = {
        { "patient", belongs_to = "PatientModel", key = "patient_id" },
        { "user",    belongs_to = "UserModel",     key = "user_id" }
    }
})

local JSON_FIELDS = { "notification_preferences", "decision_scope" }

function FamilyMemberModel:getByPatient(patient_id)
    return self:select("WHERE patient_id = ? AND status = 'active' ORDER BY is_next_of_kin DESC, last_name ASC", patient_id)
end

function FamilyMemberModel:getNextOfKin(patient_id)
    return self:select("WHERE patient_id = ? AND is_next_of_kin = true AND status = 'active' LIMIT 1", patient_id)
end

function FamilyMemberModel:getEmergencyContacts(patient_id)
    return self:select("WHERE patient_id = ? AND is_emergency_contact = true AND status = 'active'", patient_id)
end

function FamilyMemberModel:getByUser(user_id)
    return self:select("WHERE user_id = ? AND status = 'active'", user_id)
end

function FamilyMemberModel:getWithParsedData(id)
    local member = self:find(id)
    if not member then return nil end

    for _, field in ipairs(JSON_FIELDS) do
        if member[field] then
            local ok, parsed = pcall(cJson.decode, member[field])
            if ok then member[field] = parsed end
        end
    end

    return member
end

return FamilyMemberModel
