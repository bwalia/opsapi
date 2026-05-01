local Model = require("lapis.db.model").Model
local Global = require "helper.global"

local PatientAssignmentModel = Model:extend("patient_assignments", {
    timestamp = true,
    relations = {
        {"patient", belongs_to = "PatientModel", key = "patient_id"},
        {"staff", belongs_to = "HospitalStaffModel", key = "staff_id"}
    }
})

-- Create a new patient assignment
function PatientAssignmentModel:create(data)
    local assignment_data = {
        uuid = Global.generateUUID(),
        patient_id = data.patient_id,
        staff_id = data.staff_id,
        assignment_type = data.assignment_type,
        start_date = data.start_date,
        end_date = data.end_date,
        shift = data.shift,
        notes = data.notes,
        status = data.status or "active",
        created_at = Global.getCurrentTimestamp(),
        updated_at = Global.getCurrentTimestamp()
    }
    
    return self:create(assignment_data)
end

-- Update patient assignment
function PatientAssignmentModel:update(assignment_id, data)
    local update_data = {}
    
    if data.assignment_type then update_data.assignment_type = data.assignment_type end
    if data.start_date then update_data.start_date = data.start_date end
    if data.end_date then update_data.end_date = data.end_date end
    if data.shift then update_data.shift = data.shift end
    if data.notes then update_data.notes = data.notes end
    if data.status then update_data.status = data.status end
    
    update_data.updated_at = Global.getCurrentTimestamp()
    
    return self:update(assignment_id, update_data)
end

-- Get assignments by patient
function PatientAssignmentModel:getByPatient(patient_id)
    return self:select("WHERE patient_id = ? ORDER BY assignment_type ASC, start_date DESC", patient_id)
end

-- Get active assignments by patient
function PatientAssignmentModel:getActiveByPatient(patient_id)
    return self:select("WHERE patient_id = ? AND status = 'active' ORDER BY assignment_type ASC", patient_id)
end

-- Get assignments by staff
function PatientAssignmentModel:getByStaff(staff_id)
    return self:select("WHERE staff_id = ? ORDER BY assignment_type ASC, start_date DESC", staff_id)
end

-- Get active assignments by staff
function PatientAssignmentModel:getActiveByStaff(staff_id)
    return self:select("WHERE staff_id = ? AND status = 'active' ORDER BY assignment_type ASC", staff_id)
end

-- Get assignments by type
function PatientAssignmentModel:getByType(patient_id, assignment_type)
    return self:select("WHERE patient_id = ? AND assignment_type = ? ORDER BY start_date DESC", patient_id, assignment_type)
end

-- Get assignments with patient and staff details
function PatientAssignmentModel:getWithDetails(patient_id)
    local db = require("lapis.db")
    
    return db.select([[
        SELECT pa.*, 
               p.first_name as patient_first_name, p.last_name as patient_last_name, p.patient_id as patient_number,
               hs.department, hs.position, hs.specialization,
               u.first_name as staff_first_name, u.last_name as staff_last_name, u.email as staff_email
        FROM patient_assignments pa
        LEFT JOIN patients p ON pa.patient_id = p.id
        LEFT JOIN hospital_staff hs ON pa.staff_id = hs.id
        LEFT JOIN users u ON hs.user_id = u.id
        WHERE pa.patient_id = ?
        ORDER BY pa.assignment_type ASC, pa.start_date DESC
    ]], patient_id)
end

-- End assignment
function PatientAssignmentModel:endAssignment(assignment_id, end_date)
    local update_data = {
        end_date = end_date or Global.getCurrentTimestamp():sub(1, 10),
        status = "completed",
        updated_at = Global.getCurrentTimestamp()
    }
    
    return self:update(assignment_id, update_data)
end

-- Get current assignments for a patient
function PatientAssignmentModel:getCurrentAssignments(patient_id)
    local db = require("lapis.db")
    
    return db.select([[
        SELECT pa.*, 
               hs.department, hs.position, hs.specialization,
               u.first_name as staff_first_name, u.last_name as staff_last_name
        FROM patient_assignments pa
        LEFT JOIN hospital_staff hs ON pa.staff_id = hs.id
        LEFT JOIN users u ON hs.user_id = u.id
        WHERE pa.patient_id = ? AND pa.status = 'active' 
        AND (pa.end_date IS NULL OR pa.end_date >= CURRENT_DATE)
        ORDER BY pa.assignment_type ASC
    ]], patient_id)
end

-- Get assignment statistics
function PatientAssignmentModel:getStatistics(hospital_id)
    local db = require("lapis.db")
    
    local stats = {}
    
    -- Total assignments
    local total_assignments = db.select([[
        SELECT COUNT(*) as count 
        FROM patient_assignments pa
        LEFT JOIN patients p ON pa.patient_id = p.id
        WHERE p.hospital_id = ?
    ]], hospital_id)
    stats.total_assignments = total_assignments[1] and total_assignments[1].count or 0
    
    -- Active assignments
    local active_assignments = db.select([[
        SELECT COUNT(*) as count 
        FROM patient_assignments pa
        LEFT JOIN patients p ON pa.patient_id = p.id
        WHERE p.hospital_id = ? AND pa.status = 'active'
    ]], hospital_id)
    stats.active_assignments = active_assignments[1] and active_assignments[1].count or 0
    
    -- Assignments by type
    local assignments_by_type = db.select([[
        SELECT pa.assignment_type, COUNT(*) as count 
        FROM patient_assignments pa
        LEFT JOIN patients p ON pa.patient_id = p.id
        WHERE p.hospital_id = ?
        GROUP BY pa.assignment_type
    ]], hospital_id)
    stats.by_type = {}
    for _, row in ipairs(assignments_by_type) do
        stats.by_type[row.assignment_type] = row.count
    end
    
    return stats
end

return PatientAssignmentModel
