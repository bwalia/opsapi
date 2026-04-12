local Model = require("lapis.db.model").Model
local cJson = require("cjson")
local Global = require "helper.global"

local CareLogModel = Model:extend("care_logs", {
    timestamp = true,
    relations = {
        { "patient",   belongs_to = "PatientModel",  key = "patient_id" },
        { "care_plan", belongs_to = "CarePlanModel",  key = "care_plan_id" },
        { "staff",     belongs_to = "HospitalStaffModel", key = "staff_id" }
    }
})

function CareLogModel:getByPatient(patient_id, filters)
    local where = "WHERE patient_id = ?"
    local params = { patient_id }

    if filters then
        if filters.log_type then
            where = where .. " AND log_type = ?"
            table.insert(params, filters.log_type)
        end
        if filters.log_date then
            where = where .. " AND log_date = ?"
            table.insert(params, filters.log_date)
        end
        if filters.shift then
            where = where .. " AND shift = ?"
            table.insert(params, filters.shift)
        end
    end

    where = where .. " ORDER BY log_date DESC, log_time DESC"
    return self:select(where, unpack(params))
end

function CareLogModel:getByDateRange(patient_id, start_date, end_date)
    return self:select(
        "WHERE patient_id = ? AND log_date >= ? AND log_date <= ? ORDER BY log_date DESC, log_time DESC",
        patient_id, start_date, end_date
    )
end

function CareLogModel:getIncidents(patient_id)
    return self:select(
        "WHERE patient_id = ? AND log_type = 'incident' ORDER BY log_date DESC, log_time DESC",
        patient_id
    )
end

function CareLogModel:getWithParsedData(id)
    local log = self:find(id)
    if not log then return nil end

    if log.details then
        local ok, parsed = pcall(cJson.decode, log.details)
        if ok then log.details = parsed end
    end

    return log
end

return CareLogModel
