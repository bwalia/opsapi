local Model = require("lapis.db.model").Model
local Global = require "helper.global"

local HospitalStaffModel = Model:extend("hospital_staff", {
    timestamp = true,
    relations = {
        {"hospital", belongs_to = "HospitalModel", key = "hospital_id"},
        {"user", belongs_to = "UserModel", key = "user_id"},
        {"patient_assignments", has_many = "PatientAssignmentModel", key = "staff_id"},
        {"appointments", has_many = "PatientAppointmentModel", key = "staff_id"}
    }
})

-- Create a new staff member
function HospitalStaffModel:create(data)
    local staff_data = {
        uuid = Global.generateUUID(),
        hospital_id = data.hospital_id,
        user_id = data.user_id,
        employee_id = data.employee_id,
        department = data.department,
        position = data.position,
        specialization = data.specialization,
        license_number = data.license_number,
        shift = data.shift,
        phone = data.phone,
        email = data.email,
        hire_date = data.hire_date,
        status = data.status or "active",
        notes = data.notes,
        created_at = Global.getCurrentTimestamp(),
        updated_at = Global.getCurrentTimestamp()
    }
    
    return self:create(staff_data)
end

-- Update staff member
function HospitalStaffModel:update(staff_id, data)
    local update_data = {}
    
    if data.department then update_data.department = data.department end
    if data.position then update_data.position = data.position end
    if data.specialization then update_data.specialization = data.specialization end
    if data.license_number then update_data.license_number = data.license_number end
    if data.shift then update_data.shift = data.shift end
    if data.phone then update_data.phone = data.phone end
    if data.email then update_data.email = data.email end
    if data.hire_date then update_data.hire_date = data.hire_date end
    if data.status then update_data.status = data.status end
    if data.notes then update_data.notes = data.notes end
    
    update_data.updated_at = Global.getCurrentTimestamp()
    
    return self:update(staff_id, update_data)
end

-- Get staff by hospital
function HospitalStaffModel:getByHospital(hospital_id)
    return self:select("WHERE hospital_id = ? ORDER BY department ASC, position ASC", hospital_id)
end

-- Get active staff by hospital
function HospitalStaffModel:getActiveByHospital(hospital_id)
    return self:select("WHERE hospital_id = ? AND status = 'active' ORDER BY department ASC, position ASC", hospital_id)
end

-- Get staff by department
function HospitalStaffModel:getByDepartment(hospital_id, department)
    return self:select("WHERE hospital_id = ? AND department = ? ORDER BY position ASC", hospital_id, department)
end

-- Get staff by position
function HospitalStaffModel:getByPosition(hospital_id, position)
    return self:select("WHERE hospital_id = ? AND position = ? ORDER BY department ASC", hospital_id, position)
end

-- Search staff by criteria
function HospitalStaffModel:search(criteria)
    local conditions = {}
    local params = {}
    
    if criteria.hospital_id then
        table.insert(conditions, "hospital_id = ?")
        table.insert(params, criteria.hospital_id)
    end
    
    if criteria.department then
        table.insert(conditions, "department ILIKE ?")
        table.insert(params, "%" .. criteria.department .. "%")
    end
    
    if criteria.position then
        table.insert(conditions, "position ILIKE ?")
        table.insert(params, "%" .. criteria.position .. "%")
    end
    
    if criteria.specialization then
        table.insert(conditions, "specialization ILIKE ?")
        table.insert(params, "%" .. criteria.specialization .. "%")
    end
    
    if criteria.shift then
        table.insert(conditions, "shift = ?")
        table.insert(params, criteria.shift)
    end
    
    if criteria.status then
        table.insert(conditions, "status = ?")
        table.insert(params, criteria.status)
    end
    
    local where_clause = ""
    if #conditions > 0 then
        where_clause = "WHERE " .. table.concat(conditions, " AND ")
    end
    
    local query = "SELECT hs.*, u.first_name, u.last_name, u.email as user_email FROM hospital_staff hs LEFT JOIN users u ON hs.user_id = u.id " .. where_clause .. " ORDER BY hs.department ASC, hs.position ASC"
    
    return self.db.select(query, unpack(params))
end

-- Get staff with user details
function HospitalStaffModel:getWithUserDetails(staff_id)
    local db = require("lapis.db")
    
    local result = db.select("SELECT hs.*, u.first_name, u.last_name, u.email as user_email FROM hospital_staff hs LEFT JOIN users u ON hs.user_id = u.id WHERE hs.id = ?", staff_id)
    
    if result and #result > 0 then
        return result[1]
    end
    
    return nil
end

-- Get staff statistics
function HospitalStaffModel:getStatistics(hospital_id)
    local db = require("lapis.db")
    
    local stats = {}
    
    -- Total staff
    local total_staff = db.select("SELECT COUNT(*) as count FROM hospital_staff WHERE hospital_id = ?", hospital_id)
    stats.total_staff = total_staff[1] and total_staff[1].count or 0
    
    -- Active staff
    local active_staff = db.select("SELECT COUNT(*) as count FROM hospital_staff WHERE hospital_id = ? AND status = 'active'", hospital_id)
    stats.active_staff = active_staff[1] and active_staff[1].count or 0
    
    -- Staff by department
    local staff_by_dept = db.select("SELECT department, COUNT(*) as count FROM hospital_staff WHERE hospital_id = ? GROUP BY department", hospital_id)
    stats.by_department = {}
    for _, row in ipairs(staff_by_dept) do
        stats.by_department[row.department] = row.count
    end
    
    -- Staff by position
    local staff_by_position = db.select("SELECT position, COUNT(*) as count FROM hospital_staff WHERE hospital_id = ? GROUP BY position", hospital_id)
    stats.by_position = {}
    for _, row in ipairs(staff_by_position) do
        stats.by_position[row.position] = row.count
    end
    
    -- Staff by shift
    local staff_by_shift = db.select("SELECT shift, COUNT(*) as count FROM hospital_staff WHERE hospital_id = ? GROUP BY shift", hospital_id)
    stats.by_shift = {}
    for _, row in ipairs(staff_by_shift) do
        stats.by_shift[row.shift] = row.count
    end
    
    return stats
end

-- Get staff assignments for a patient
function HospitalStaffModel:getPatientAssignments(patient_id)
    local db = require("lapis.db")
    
    return db.select([[
        SELECT hs.*, pa.assignment_type, pa.start_date, pa.end_date, pa.shift, pa.notes, pa.status as assignment_status,
               u.first_name, u.last_name, u.email as user_email
        FROM hospital_staff hs
        LEFT JOIN patient_assignments pa ON hs.id = pa.staff_id
        LEFT JOIN users u ON hs.user_id = u.id
        WHERE pa.patient_id = ? AND pa.status = 'active'
        ORDER BY pa.assignment_type ASC, hs.department ASC
    ]], patient_id)
end

-- Get staff appointments for a date
function HospitalStaffModel:getAppointmentsForDate(staff_id, date)
    local db = require("lapis.db")
    
    return db.select([[
        SELECT pa.*, p.first_name, p.last_name, p.patient_id as patient_number
        FROM patient_appointments pa
        LEFT JOIN patients p ON pa.patient_id = p.id
        WHERE pa.staff_id = ? AND pa.appointment_date = ?
        ORDER BY pa.appointment_time ASC
    ]], staff_id, date)
end

return HospitalStaffModel
