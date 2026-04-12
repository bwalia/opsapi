local Model = require("lapis.db.model").Model
local cJson = require("cjson")
local Global = require "helper.global"

local DailyLogModel = Model:extend("daily_logs", {
    timestamp = true,
    relations = {
        { "patient", belongs_to = "PatientModel", key = "patient_id" }
    }
})

local JSON_FIELDS = {
    "medications_given", "medications_refused", "activities",
    "mood_changes", "behavioural_incidents", "social_interactions",
    "personal_care_completed"
}

function DailyLogModel:getByPatient(patient_id, filters)
    local where = "WHERE patient_id = ?"
    local params = { patient_id }

    if filters then
        if filters.log_date then
            where = where .. " AND log_date = ?"
            table.insert(params, filters.log_date)
        end
        if filters.shift then
            where = where .. " AND shift = ?"
            table.insert(params, filters.shift)
        end
    end

    where = where .. " ORDER BY log_date DESC, shift ASC"
    return self:select(where, unpack(params))
end

function DailyLogModel:getByDateRange(patient_id, start_date, end_date)
    return self:select(
        "WHERE patient_id = ? AND log_date >= ? AND log_date <= ? ORDER BY log_date DESC",
        patient_id, start_date, end_date
    )
end

function DailyLogModel:getToday(patient_id)
    return self:select(
        "WHERE patient_id = ? AND log_date = CURRENT_DATE ORDER BY shift ASC",
        patient_id
    )
end

function DailyLogModel:getWithParsedData(id)
    local log = self:find(id)
    if not log then return nil end

    for _, field in ipairs(JSON_FIELDS) do
        if log[field] then
            local ok, parsed = pcall(cJson.decode, log[field])
            if ok then log[field] = parsed end
        end
    end

    return log
end

return DailyLogModel
