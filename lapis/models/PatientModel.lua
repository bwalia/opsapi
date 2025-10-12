local Model = require("lapis.db.model").Model
local cJson = require("cjson")
local Global = require "helper.global"

local PatientModel = Model:extend("patients", {
    timestamp = true,
    relations = {
        {"hospital", belongs_to = "HospitalModel", key = "hospital_id"},
        {"health_records", has_many = "PatientHealthRecordModel", key = "patient_id"},
        {"appointments", has_many = "PatientAppointmentModel", key = "patient_id"},
        {"documents", has_many = "PatientDocumentModel", key = "patient_id"},
        {"assignments", has_many = "PatientAssignmentModel", key = "patient_id"}
    }
})

-- Create a new patient
function PatientModel:create(data)
    local patient_data = {
        uuid = Global.generateUUID(),
        hospital_id = data.hospital_id,
        patient_id = data.patient_id,
        first_name = data.first_name,
        last_name = data.last_name,
        date_of_birth = data.date_of_birth,
        gender = data.gender,
        phone = data.phone,
        email = data.email,
        address = data.address,
        city = data.city,
        state = data.state,
        postal_code = data.postal_code,
        country = data.country,
        emergency_contact_name = data.emergency_contact_name,
        emergency_contact_phone = data.emergency_contact_phone,
        emergency_contact_relation = data.emergency_contact_relation,
        blood_type = data.blood_type,
        allergies = data.allergies and cJson.encode(data.allergies) or nil,
        medical_conditions = data.medical_conditions and cJson.encode(data.medical_conditions) or nil,
        medications = data.medications and cJson.encode(data.medications) or nil,
        insurance_provider = data.insurance_provider,
        insurance_number = data.insurance_number,
        admission_date = data.admission_date,
        discharge_date = data.discharge_date,
        room_number = data.room_number,
        bed_number = data.bed_number,
        status = data.status or "active",
        notes = data.notes,
        created_at = Global.getCurrentTimestamp(),
        updated_at = Global.getCurrentTimestamp()
    }
    
    return self:create(patient_data)
end

-- Update patient
function PatientModel:update(patient_id, data)
    local update_data = {}
    
    if data.first_name then update_data.first_name = data.first_name end
    if data.last_name then update_data.last_name = data.last_name end
    if data.date_of_birth then update_data.date_of_birth = data.date_of_birth end
    if data.gender then update_data.gender = data.gender end
    if data.phone then update_data.phone = data.phone end
    if data.email then update_data.email = data.email end
    if data.address then update_data.address = data.address end
    if data.city then update_data.city = data.city end
    if data.state then update_data.state = data.state end
    if data.postal_code then update_data.postal_code = data.postal_code end
    if data.country then update_data.country = data.country end
    if data.emergency_contact_name then update_data.emergency_contact_name = data.emergency_contact_name end
    if data.emergency_contact_phone then update_data.emergency_contact_phone = data.emergency_contact_phone end
    if data.emergency_contact_relation then update_data.emergency_contact_relation = data.emergency_contact_relation end
    if data.blood_type then update_data.blood_type = data.blood_type end
    if data.allergies then update_data.allergies = cJson.encode(data.allergies) end
    if data.medical_conditions then update_data.medical_conditions = cJson.encode(data.medical_conditions) end
    if data.medications then update_data.medications = cJson.encode(data.medications) end
    if data.insurance_provider then update_data.insurance_provider = data.insurance_provider end
    if data.insurance_number then update_data.insurance_number = data.insurance_number end
    if data.admission_date then update_data.admission_date = data.admission_date end
    if data.discharge_date then update_data.discharge_date = data.discharge_date end
    if data.room_number then update_data.room_number = data.room_number end
    if data.bed_number then update_data.bed_number = data.bed_number end
    if data.status then update_data.status = data.status end
    if data.notes then update_data.notes = data.notes end
    
    update_data.updated_at = Global.getCurrentTimestamp()
    
    return self:update(patient_id, update_data)
end

-- Get patient with parsed JSON fields
function PatientModel:getWithParsedData(patient_id)
    local patient = self:find(patient_id)
    if not patient then
        return nil
    end
    
    -- Parse JSON fields
    if patient.allergies then
        local ok, parsed = pcall(cJson.decode, patient.allergies)
        if ok then patient.allergies = parsed end
    end
    
    if patient.medical_conditions then
        local ok, parsed = pcall(cJson.decode, patient.medical_conditions)
        if ok then patient.medical_conditions = parsed end
    end
    
    if patient.medications then
        local ok, parsed = pcall(cJson.decode, patient.medications)
        if ok then patient.medications = parsed end
    end
    
    return patient
end

-- Search patients by criteria
function PatientModel:search(criteria)
    local conditions = {}
    local params = {}
    
    if criteria.hospital_id then
        table.insert(conditions, "hospital_id = ?")
        table.insert(params, criteria.hospital_id)
    end
    
    if criteria.patient_id then
        table.insert(conditions, "patient_id ILIKE ?")
        table.insert(params, "%" .. criteria.patient_id .. "%")
    end
    
    if criteria.first_name then
        table.insert(conditions, "first_name ILIKE ?")
        table.insert(params, "%" .. criteria.first_name .. "%")
    end
    
    if criteria.last_name then
        table.insert(conditions, "last_name ILIKE ?")
        table.insert(params, "%" .. criteria.last_name .. "%")
    end
    
    if criteria.room_number then
        table.insert(conditions, "room_number = ?")
        table.insert(params, criteria.room_number)
    end
    
    if criteria.status then
        table.insert(conditions, "status = ?")
        table.insert(params, criteria.status)
    end
    
    if criteria.admission_date_from then
        table.insert(conditions, "admission_date >= ?")
        table.insert(params, criteria.admission_date_from)
    end
    
    if criteria.admission_date_to then
        table.insert(conditions, "admission_date <= ?")
        table.insert(params, criteria.admission_date_to)
    end
    
    local where_clause = ""
    if #conditions > 0 then
        where_clause = "WHERE " .. table.concat(conditions, " AND ")
    end
    
    local query = "SELECT * FROM patients " .. where_clause .. " ORDER BY last_name ASC, first_name ASC"
    
    return self.db.select(query, unpack(params))
end

-- Get patients by hospital
function PatientModel:getByHospital(hospital_id)
    return self:select("WHERE hospital_id = ? ORDER BY last_name ASC, first_name ASC", hospital_id)
end

-- Get active patients
function PatientModel:getActive(hospital_id)
    if hospital_id then
        return self:select("WHERE hospital_id = ? AND status = 'active' ORDER BY last_name ASC, first_name ASC", hospital_id)
    else
        return self:select("WHERE status = 'active' ORDER BY last_name ASC, first_name ASC")
    end
end

-- Get patients by room
function PatientModel:getByRoom(hospital_id, room_number)
    return self:select("WHERE hospital_id = ? AND room_number = ? ORDER BY bed_number ASC", hospital_id, room_number)
end

-- Get patient statistics
function PatientModel:getStatistics(hospital_id)
    local db = require("lapis.db")
    
    local stats = {}
    
    -- Total patients
    local total_patients = db.select("SELECT COUNT(*) as count FROM patients WHERE hospital_id = ?", hospital_id)
    stats.total_patients = total_patients[1] and total_patients[1].count or 0
    
    -- Active patients
    local active_patients = db.select("SELECT COUNT(*) as count FROM patients WHERE hospital_id = ? AND status = 'active'", hospital_id)
    stats.active_patients = active_patients[1] and active_patients[1].count or 0
    
    -- Discharged patients
    local discharged_patients = db.select("SELECT COUNT(*) as count FROM patients WHERE hospital_id = ? AND status = 'discharged'", hospital_id)
    stats.discharged_patients = discharged_patients[1] and discharged_patients[1].count or 0
    
    -- Patients by gender
    local gender_stats = db.select("SELECT gender, COUNT(*) as count FROM patients WHERE hospital_id = ? GROUP BY gender", hospital_id)
    stats.by_gender = {}
    for _, row in ipairs(gender_stats) do
        stats.by_gender[row.gender] = row.count
    end
    
    -- Recent admissions (last 30 days)
    local recent_admissions = db.select("SELECT COUNT(*) as count FROM patients WHERE hospital_id = ? AND admission_date >= CURRENT_DATE - INTERVAL '30 days'", hospital_id)
    stats.recent_admissions = recent_admissions[1] and recent_admissions[1].count or 0
    
    return stats
end

-- Calculate patient age
function PatientModel:calculateAge(patient_id)
    local patient = self:find(patient_id)
    if not patient or not patient.date_of_birth then
        return nil
    end
    
    local birth_date = patient.date_of_birth
    local current_date = os.date("*t")
    local birth_t = os.time({year = birth_date:sub(1,4), month = birth_date:sub(6,7), day = birth_date:sub(9,10)})
    local current_t = os.time(current_date)
    
    local age = os.difftime(current_t, birth_t) / (365.25 * 24 * 60 * 60)
    return math.floor(age)
end

return PatientModel
