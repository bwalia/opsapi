local Model = require("lapis.db.model").Model
local Global = require "helper.global"

local PatientAppointmentModel = Model:extend("patient_appointments", {
    timestamp = true,
    relations = {
        {"patient", belongs_to = "PatientModel", key = "patient_id"},
        {"staff", belongs_to = "HospitalStaffModel", key = "staff_id"}
    }
})

-- Create a new appointment
function PatientAppointmentModel:create(data)
    local appointment_data = {
        uuid = Global.generateUUID(),
        patient_id = data.patient_id,
        staff_id = data.staff_id,
        appointment_type = data.appointment_type,
        appointment_date = data.appointment_date,
        appointment_time = data.appointment_time,
        duration = data.duration or 30,
        location = data.location,
        status = data.status or "scheduled",
        notes = data.notes,
        follow_up_required = data.follow_up_required or false,
        follow_up_date = data.follow_up_date,
        created_at = Global.getCurrentTimestamp(),
        updated_at = Global.getCurrentTimestamp()
    }
    
    return self:create(appointment_data)
end

-- Update appointment
function PatientAppointmentModel:update(appointment_id, data)
    local update_data = {}
    
    if data.appointment_type then update_data.appointment_type = data.appointment_type end
    if data.appointment_date then update_data.appointment_date = data.appointment_date end
    if data.appointment_time then update_data.appointment_time = data.appointment_time end
    if data.duration then update_data.duration = data.duration end
    if data.location then update_data.location = data.location end
    if data.status then update_data.status = data.status end
    if data.notes then update_data.notes = data.notes end
    if data.follow_up_required ~= nil then update_data.follow_up_required = data.follow_up_required end
    if data.follow_up_date then update_data.follow_up_date = data.follow_up_date end
    
    update_data.updated_at = Global.getCurrentTimestamp()
    
    return self:update(appointment_id, update_data)
end

-- Get appointments by patient
function PatientAppointmentModel:getByPatient(patient_id, limit, offset)
    local query = "WHERE patient_id = ? ORDER BY appointment_date DESC, appointment_time DESC"
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

-- Get appointments by staff
function PatientAppointmentModel:getByStaff(staff_id, limit, offset)
    local query = "WHERE staff_id = ? ORDER BY appointment_date DESC, appointment_time DESC"
    local params = {staff_id}
    
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

-- Get appointments by date
function PatientAppointmentModel:getByDate(date, hospital_id)
    local db = require("lapis.db")
    
    if hospital_id then
        return db.select([[
            SELECT pa.*, p.first_name, p.last_name, p.patient_id as patient_number,
                   hs.department, hs.position,
                   u.first_name as staff_first_name, u.last_name as staff_last_name
            FROM patient_appointments pa
            LEFT JOIN patients p ON pa.patient_id = p.id
            LEFT JOIN hospital_staff hs ON pa.staff_id = hs.id
            LEFT JOIN users u ON hs.user_id = u.id
            WHERE pa.appointment_date = ? AND p.hospital_id = ?
            ORDER BY pa.appointment_time ASC
        ]], date, hospital_id)
    else
        return db.select([[
            SELECT pa.*, p.first_name, p.last_name, p.patient_id as patient_number,
                   hs.department, hs.position,
                   u.first_name as staff_first_name, u.last_name as staff_last_name
            FROM patient_appointments pa
            LEFT JOIN patients p ON pa.patient_id = p.id
            LEFT JOIN hospital_staff hs ON pa.staff_id = hs.id
            LEFT JOIN users u ON hs.user_id = u.id
            WHERE pa.appointment_date = ?
            ORDER BY pa.appointment_time ASC
        ]], date)
    end
end

-- Get appointments by date range
function PatientAppointmentModel:getByDateRange(start_date, end_date, hospital_id)
    local db = require("lapis.db")
    
    if hospital_id then
        return db.select([[
            SELECT pa.*, p.first_name, p.last_name, p.patient_id as patient_number,
                   hs.department, hs.position,
                   u.first_name as staff_first_name, u.last_name as staff_last_name
            FROM patient_appointments pa
            LEFT JOIN patients p ON pa.patient_id = p.id
            LEFT JOIN hospital_staff hs ON pa.staff_id = hs.id
            LEFT JOIN users u ON hs.user_id = u.id
            WHERE pa.appointment_date >= ? AND pa.appointment_date <= ? AND p.hospital_id = ?
            ORDER BY pa.appointment_date ASC, pa.appointment_time ASC
        ]], start_date, end_date, hospital_id)
    else
        return db.select([[
            SELECT pa.*, p.first_name, p.last_name, p.patient_id as patient_number,
                   hs.department, hs.position,
                   u.first_name as staff_first_name, u.last_name as staff_last_name
            FROM patient_appointments pa
            LEFT JOIN patients p ON pa.patient_id = p.id
            LEFT JOIN hospital_staff hs ON pa.staff_id = hs.id
            LEFT JOIN users u ON hs.user_id = u.id
            WHERE pa.appointment_date >= ? AND pa.appointment_date <= ?
            ORDER BY pa.appointment_date ASC, pa.appointment_time ASC
        ]], start_date, end_date)
    end
end

-- Get appointments by status
function PatientAppointmentModel:getByStatus(status, hospital_id)
    local db = require("lapis.db")
    
    if hospital_id then
        return db.select([[
            SELECT pa.*, p.first_name, p.last_name, p.patient_id as patient_number,
                   hs.department, hs.position,
                   u.first_name as staff_first_name, u.last_name as staff_last_name
            FROM patient_appointments pa
            LEFT JOIN patients p ON pa.patient_id = p.id
            LEFT JOIN hospital_staff hs ON pa.staff_id = hs.id
            LEFT JOIN users u ON hs.user_id = u.id
            WHERE pa.status = ? AND p.hospital_id = ?
            ORDER BY pa.appointment_date ASC, pa.appointment_time ASC
        ]], status, hospital_id)
    else
        return db.select([[
            SELECT pa.*, p.first_name, p.last_name, p.patient_id as patient_number,
                   hs.department, hs.position,
                   u.first_name as staff_first_name, u.last_name as staff_last_name
            FROM patient_appointments pa
            LEFT JOIN patients p ON pa.patient_id = p.id
            LEFT JOIN hospital_staff hs ON pa.staff_id = hs.id
            LEFT JOIN users u ON hs.user_id = u.id
            WHERE pa.status = ?
            ORDER BY pa.appointment_date ASC, pa.appointment_time ASC
        ]], status)
    end
end

-- Get upcoming appointments
function PatientAppointmentModel:getUpcoming(hospital_id, days_ahead)
    local db = require("lapis.db")
    days_ahead = days_ahead or 7
    
    if hospital_id then
        return db.select([[
            SELECT pa.*, p.first_name, p.last_name, p.patient_id as patient_number,
                   hs.department, hs.position,
                   u.first_name as staff_first_name, u.last_name as staff_last_name
            FROM patient_appointments pa
            LEFT JOIN patients p ON pa.patient_id = p.id
            LEFT JOIN hospital_staff hs ON pa.staff_id = hs.id
            LEFT JOIN users u ON hs.user_id = u.id
            WHERE pa.appointment_date >= CURRENT_DATE 
            AND pa.appointment_date <= CURRENT_DATE + INTERVAL ? DAYS
            AND pa.status IN ('scheduled', 'confirmed')
            AND p.hospital_id = ?
            ORDER BY pa.appointment_date ASC, pa.appointment_time ASC
        ]], days_ahead, hospital_id)
    else
        return db.select([[
            SELECT pa.*, p.first_name, p.last_name, p.patient_id as patient_number,
                   hs.department, hs.position,
                   u.first_name as staff_first_name, u.last_name as staff_last_name
            FROM patient_appointments pa
            LEFT JOIN patients p ON pa.patient_id = p.id
            LEFT JOIN hospital_staff hs ON pa.staff_id = hs.id
            LEFT JOIN users u ON hs.user_id = u.id
            WHERE pa.appointment_date >= CURRENT_DATE 
            AND pa.appointment_date <= CURRENT_DATE + INTERVAL ? DAYS
            AND pa.status IN ('scheduled', 'confirmed')
            ORDER BY pa.appointment_date ASC, pa.appointment_time ASC
        ]], days_ahead)
    end
end

-- Get appointments requiring follow-up
function PatientAppointmentModel:getFollowUpRequired(hospital_id)
    local db = require("lapis.db")
    
    if hospital_id then
        return db.select([[
            SELECT pa.*, p.first_name, p.last_name, p.patient_id as patient_number,
                   hs.department, hs.position,
                   u.first_name as staff_first_name, u.last_name as staff_last_name
            FROM patient_appointments pa
            LEFT JOIN patients p ON pa.patient_id = p.id
            LEFT JOIN hospital_staff hs ON pa.staff_id = hs.id
            LEFT JOIN users u ON hs.user_id = u.id
            WHERE pa.follow_up_required = true AND p.hospital_id = ?
            ORDER BY pa.follow_up_date ASC
        ]], hospital_id)
    else
        return db.select([[
            SELECT pa.*, p.first_name, p.last_name, p.patient_id as patient_number,
                   hs.department, hs.position,
                   u.first_name as staff_first_name, u.last_name as staff_last_name
            FROM patient_appointments pa
            LEFT JOIN patients p ON pa.patient_id = p.id
            LEFT JOIN hospital_staff hs ON pa.staff_id = hs.id
            LEFT JOIN users u ON hs.user_id = u.id
            WHERE pa.follow_up_required = true
            ORDER BY pa.follow_up_date ASC
        ]])
    end
end

-- Get appointment statistics
function PatientAppointmentModel:getStatistics(hospital_id)
    local db = require("lapis.db")
    
    local stats = {}
    
    -- Total appointments
    local total_appointments = db.select([[
        SELECT COUNT(*) as count 
        FROM patient_appointments pa
        LEFT JOIN patients p ON pa.patient_id = p.id
        WHERE p.hospital_id = ?
    ]], hospital_id)
    stats.total_appointments = total_appointments[1] and total_appointments[1].count or 0
    
    -- Appointments by status
    local appointments_by_status = db.select([[
        SELECT pa.status, COUNT(*) as count 
        FROM patient_appointments pa
        LEFT JOIN patients p ON pa.patient_id = p.id
        WHERE p.hospital_id = ?
        GROUP BY pa.status
    ]], hospital_id)
    stats.by_status = {}
    for _, row in ipairs(appointments_by_status) do
        stats.by_status[row.status] = row.count
    end
    
    -- Appointments by type
    local appointments_by_type = db.select([[
        SELECT pa.appointment_type, COUNT(*) as count 
        FROM patient_appointments pa
        LEFT JOIN patients p ON pa.patient_id = p.id
        WHERE p.hospital_id = ?
        GROUP BY pa.appointment_type
    ]], hospital_id)
    stats.by_type = {}
    for _, row in ipairs(appointments_by_type) do
        stats.by_type[row.appointment_type] = row.count
    end
    
    -- Today's appointments
    local todays_appointments = db.select([[
        SELECT COUNT(*) as count 
        FROM patient_appointments pa
        LEFT JOIN patients p ON pa.patient_id = p.id
        WHERE pa.appointment_date = CURRENT_DATE AND p.hospital_id = ?
    ]], hospital_id)
    stats.todays_appointments = todays_appointments[1] and todays_appointments[1].count or 0
    
    return stats
end

return PatientAppointmentModel
