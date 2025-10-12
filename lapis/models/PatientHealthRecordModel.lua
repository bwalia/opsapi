local Model = require("lapis.db.model").Model
local Global = require "helper.global"

local PatientHealthRecordModel = Model:extend("patient_health_records", {
    timestamp = true,
    relations = {
        {"patient", belongs_to = "PatientModel", key = "patient_id"}
    }
})

-- Create a new health record
function PatientHealthRecordModel:create(data)
    local record_data = {
        uuid = Global.generateUUID(),
        patient_id = data.patient_id,
        record_type = data.record_type,
        record_date = data.record_date,
        record_time = data.record_time,
        recorded_by = data.recorded_by,
        temperature = data.temperature,
        blood_pressure_systolic = data.blood_pressure_systolic,
        blood_pressure_diastolic = data.blood_pressure_diastolic,
        heart_rate = data.heart_rate,
        respiratory_rate = data.respiratory_rate,
        oxygen_saturation = data.oxygen_saturation,
        weight = data.weight,
        height = data.height,
        pain_level = data.pain_level,
        medication_name = data.medication_name,
        medication_dose = data.medication_dose,
        medication_time = data.medication_time,
        medication_notes = data.medication_notes,
        meal_type = data.meal_type,
        meal_intake = data.meal_intake,
        meal_notes = data.meal_notes,
        activity_type = data.activity_type,
        activity_duration = data.activity_duration,
        activity_notes = data.activity_notes,
        procedure_name = data.procedure_name,
        procedure_notes = data.procedure_notes,
        general_notes = data.general_notes,
        follow_up_required = data.follow_up_required or false,
        follow_up_date = data.follow_up_date,
        created_at = Global.getCurrentTimestamp(),
        updated_at = Global.getCurrentTimestamp()
    }
    
    return self:create(record_data)
end

-- Update health record
function PatientHealthRecordModel:update(record_id, data)
    local update_data = {}
    
    if data.record_type then update_data.record_type = data.record_type end
    if data.record_date then update_data.record_date = data.record_date end
    if data.record_time then update_data.record_time = data.record_time end
    if data.recorded_by then update_data.recorded_by = data.recorded_by end
    if data.temperature then update_data.temperature = data.temperature end
    if data.blood_pressure_systolic then update_data.blood_pressure_systolic = data.blood_pressure_systolic end
    if data.blood_pressure_diastolic then update_data.blood_pressure_diastolic = data.blood_pressure_diastolic end
    if data.heart_rate then update_data.heart_rate = data.heart_rate end
    if data.respiratory_rate then update_data.respiratory_rate = data.respiratory_rate end
    if data.oxygen_saturation then update_data.oxygen_saturation = data.oxygen_saturation end
    if data.weight then update_data.weight = data.weight end
    if data.height then update_data.height = data.height end
    if data.pain_level then update_data.pain_level = data.pain_level end
    if data.medication_name then update_data.medication_name = data.medication_name end
    if data.medication_dose then update_data.medication_dose = data.medication_dose end
    if data.medication_time then update_data.medication_time = data.medication_time end
    if data.medication_notes then update_data.medication_notes = data.medication_notes end
    if data.meal_type then update_data.meal_type = data.meal_type end
    if data.meal_intake then update_data.meal_intake = data.meal_intake end
    if data.meal_notes then update_data.meal_notes = data.meal_notes end
    if data.activity_type then update_data.activity_type = data.activity_type end
    if data.activity_duration then update_data.activity_duration = data.activity_duration end
    if data.activity_notes then update_data.activity_notes = data.activity_notes end
    if data.procedure_name then update_data.procedure_name = data.procedure_name end
    if data.procedure_notes then update_data.procedure_notes = data.procedure_notes end
    if data.general_notes then update_data.general_notes = data.general_notes end
    if data.follow_up_required ~= nil then update_data.follow_up_required = data.follow_up_required end
    if data.follow_up_date then update_data.follow_up_date = data.follow_up_date end
    
    update_data.updated_at = Global.getCurrentTimestamp()
    
    return self:update(record_id, update_data)
end

-- Get health records by patient
function PatientHealthRecordModel:getByPatient(patient_id, limit, offset)
    local query = "WHERE patient_id = ? ORDER BY record_date DESC, record_time DESC"
    local params = {patient_id}
    
    if limit then
        query = query .. " LIMIT ?"
        table.insert(params, limit)
        
        if offset then
            query = query .. " OFFSET ?"
            table.insert(params, offset)
        end
    end
    
    return self:select(query, unpack(params))
end

-- Get health records by date range
function PatientHealthRecordModel:getByDateRange(patient_id, start_date, end_date)
    return self:select("WHERE patient_id = ? AND record_date >= ? AND record_date <= ? ORDER BY record_date DESC, record_time DESC", 
        patient_id, start_date, end_date)
end

-- Get health records by type
function PatientHealthRecordModel:getByType(patient_id, record_type, limit)
    local query = "WHERE patient_id = ? AND record_type = ? ORDER BY record_date DESC, record_time DESC"
    local params = {patient_id, record_type}
    
    if limit then
        query = query .. " LIMIT ?"
        table.insert(params, limit)
    end
    
    return self:select(query, unpack(params))
end

-- Get latest vital signs for a patient
function PatientHealthRecordModel:getLatestVitals(patient_id)
    return self:select("WHERE patient_id = ? AND record_type = 'vital_signs' ORDER BY record_date DESC, record_time DESC LIMIT 1", patient_id)
end

-- Get medication history for a patient
function PatientHealthRecordModel:getMedicationHistory(patient_id, limit)
    local query = "WHERE patient_id = ? AND record_type = 'medication' ORDER BY record_date DESC, record_time DESC"
    local params = {patient_id}
    
    if limit then
        query = query .. " LIMIT ?"
        table.insert(params, limit)
    end
    
    return self:select(query, unpack(params))
end

-- Get meal records for a patient
function PatientHealthRecordModel:getMealRecords(patient_id, date)
    if date then
        return self:select("WHERE patient_id = ? AND record_type = 'meal' AND record_date = ? ORDER BY record_time ASC", 
            patient_id, date)
    else
        return self:select("WHERE patient_id = ? AND record_type = 'meal' ORDER BY record_date DESC, record_time DESC", patient_id)
    end
end

-- Get activity records for a patient
function PatientHealthRecordModel:getActivityRecords(patient_id, limit)
    local query = "WHERE patient_id = ? AND record_type = 'activity' ORDER BY record_date DESC, record_time DESC"
    local params = {patient_id}
    
    if limit then
        query = query .. " LIMIT ?"
        table.insert(params, limit)
    end
    
    return self:select(query, unpack(params))
end

-- Get records requiring follow-up
function PatientHealthRecordModel:getFollowUpRequired(patient_id)
    return self:select("WHERE patient_id = ? AND follow_up_required = true ORDER BY follow_up_date ASC", patient_id)
end

-- Get health record statistics for a patient
function PatientHealthRecordModel:getStatistics(patient_id)
    local db = require("lapis.db")
    
    local stats = {}
    
    -- Total records
    local total_records = db.select("SELECT COUNT(*) as count FROM patient_health_records WHERE patient_id = ?", patient_id)
    stats.total_records = total_records[1] and total_records[1].count or 0
    
    -- Records by type
    local records_by_type = db.select("SELECT record_type, COUNT(*) as count FROM patient_health_records WHERE patient_id = ? GROUP BY record_type", patient_id)
    stats.by_type = {}
    for _, row in ipairs(records_by_type) do
        stats.by_type[row.record_type] = row.count
    end
    
    -- Records requiring follow-up
    local follow_up_count = db.select("SELECT COUNT(*) as count FROM patient_health_records WHERE patient_id = ? AND follow_up_required = true", patient_id)
    stats.follow_up_required = follow_up_count[1] and follow_up_count[1].count or 0
    
    -- Recent records (last 7 days)
    local recent_records = db.select("SELECT COUNT(*) as count FROM patient_health_records WHERE patient_id = ? AND record_date >= CURRENT_DATE - INTERVAL '7 days'", patient_id)
    stats.recent_records = recent_records[1] and recent_records[1].count or 0
    
    return stats
end

-- Get daily summary for a patient
function PatientHealthRecordModel:getDailySummary(patient_id, date)
    local db = require("lapis.db")
    
    local summary = {}
    
    -- Vital signs for the day
    local vitals = db.select("SELECT * FROM patient_health_records WHERE patient_id = ? AND record_type = 'vital_signs' AND record_date = ? ORDER BY record_time DESC", 
        patient_id, date)
    summary.vitals = vitals
    
    -- Medications for the day
    local medications = db.select("SELECT * FROM patient_health_records WHERE patient_id = ? AND record_type = 'medication' AND record_date = ? ORDER BY record_time ASC", 
        patient_id, date)
    summary.medications = medications
    
    -- Meals for the day
    local meals = db.select("SELECT * FROM patient_health_records WHERE patient_id = ? AND record_type = 'meal' AND record_date = ? ORDER BY record_time ASC", 
        patient_id, date)
    summary.meals = meals
    
    -- Activities for the day
    local activities = db.select("SELECT * FROM patient_health_records WHERE patient_id = ? AND record_type = 'activity' AND record_date = ? ORDER BY record_time ASC", 
        patient_id, date)
    summary.activities = activities
    
    -- General notes for the day
    local notes = db.select("SELECT * FROM patient_health_records WHERE patient_id = ? AND record_type = 'note' AND record_date = ? ORDER BY record_time DESC", 
        patient_id, date)
    summary.notes = notes
    
    return summary
end

return PatientHealthRecordModel
