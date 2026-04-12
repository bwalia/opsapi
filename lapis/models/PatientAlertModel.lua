local Model = require("lapis.db.model").Model
local cJson = require("cjson")
local Global = require "helper.global"

local PatientAlertModel = Model:extend("patient_alerts", {
    timestamp = true,
    relations = {
        { "patient",  belongs_to = "PatientModel",  key = "patient_id" },
        { "hospital", belongs_to = "HospitalModel",  key = "hospital_id" }
    }
})

function PatientAlertModel:getByPatient(patient_id)
    return self:select("WHERE patient_id = ? ORDER BY created_at DESC", patient_id)
end

function PatientAlertModel:getActive(hospital_id)
    return self:select(
        "WHERE hospital_id = ? AND status IN ('active', 'escalated') ORDER BY severity DESC, created_at DESC",
        hospital_id
    )
end

function PatientAlertModel:getCritical(hospital_id)
    return self:select(
        "WHERE hospital_id = ? AND severity IN ('critical', 'emergency') AND status = 'active' ORDER BY created_at DESC",
        hospital_id
    )
end

function PatientAlertModel:getByStaff(assigned_to)
    return self:select(
        "WHERE assigned_to = ? AND status IN ('active', 'escalated') ORDER BY severity DESC, created_at DESC",
        assigned_to
    )
end

function PatientAlertModel:acknowledge(id, acknowledged_by)
    local record = self:find(id)
    if not record then return nil end
    record:update({
        status = "acknowledged",
        acknowledged_by = acknowledged_by,
        acknowledged_at = Global.getCurrentTimestamp(),
        updated_at = Global.getCurrentTimestamp()
    })
    return record
end

function PatientAlertModel:resolve(id, resolved_by, notes)
    local record = self:find(id)
    if not record then return nil end
    record:update({
        status = "resolved",
        resolved_by = resolved_by,
        resolved_at = Global.getCurrentTimestamp(),
        resolution_notes = notes,
        updated_at = Global.getCurrentTimestamp()
    })
    return record
end

function PatientAlertModel:getWithParsedData(id)
    local alert = self:find(id)
    if not alert then return nil end

    if alert.details then
        local ok, parsed = pcall(cJson.decode, alert.details)
        if ok then alert.details = parsed end
    end
    if alert.triggered_rule then
        local ok, parsed = pcall(cJson.decode, alert.triggered_rule)
        if ok then alert.triggered_rule = parsed end
    end
    if alert.notification_channels then
        local ok, parsed = pcall(cJson.decode, alert.notification_channels)
        if ok then alert.notification_channels = parsed end
    end

    return alert
end

return PatientAlertModel
