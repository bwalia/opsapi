local Model = require("lapis.db.model").Model
local cJson = require("cjson")
local Global = require "helper.global"

local HospitalModel = Model:extend("hospitals", {
    timestamp = true,
    relations = {
        {"patients", has_many = "PatientModel", key = "hospital_id"},
        {"staff", has_many = "HospitalStaffModel", key = "hospital_id"}
    }
})

-- Create a new hospital
function HospitalModel:create(data)
    local hospital_data = {
        uuid = Global.generateUUID(),
        name = data.name,
        type = data.type or "hospital",
        license_number = data.license_number,
        address = data.address,
        city = data.city,
        state = data.state,
        postal_code = data.postal_code,
        country = data.country,
        phone = data.phone,
        email = data.email,
        website = data.website,
        capacity = data.capacity or 0,
        specialties = data.specialties and cJson.encode(data.specialties) or nil,
        services = data.services and cJson.encode(data.services) or nil,
        facilities = data.facilities and cJson.encode(data.facilities) or nil,
        emergency_services = data.emergency_services or false,
        operating_hours = data.operating_hours and cJson.encode(data.operating_hours) or nil,
        contact_person = data.contact_person,
        contact_phone = data.contact_phone,
        status = data.status or "active",
        created_at = Global.getCurrentTimestamp(),
        updated_at = Global.getCurrentTimestamp()
    }
    
    return self:create(hospital_data)
end

-- Update hospital
function HospitalModel:update(hospital_id, data)
    local update_data = {}
    
    if data.name then update_data.name = data.name end
    if data.type then update_data.type = data.type end
    if data.license_number then update_data.license_number = data.license_number end
    if data.address then update_data.address = data.address end
    if data.city then update_data.city = data.city end
    if data.state then update_data.state = data.state end
    if data.postal_code then update_data.postal_code = data.postal_code end
    if data.country then update_data.country = data.country end
    if data.phone then update_data.phone = data.phone end
    if data.email then update_data.email = data.email end
    if data.website then update_data.website = data.website end
    if data.capacity then update_data.capacity = data.capacity end
    if data.specialties then update_data.specialties = cJson.encode(data.specialties) end
    if data.services then update_data.services = cJson.encode(data.services) end
    if data.facilities then update_data.facilities = cJson.encode(data.facilities) end
    if data.emergency_services ~= nil then update_data.emergency_services = data.emergency_services end
    if data.operating_hours then update_data.operating_hours = cJson.encode(data.operating_hours) end
    if data.contact_person then update_data.contact_person = data.contact_person end
    if data.contact_phone then update_data.contact_phone = data.contact_phone end
    if data.status then update_data.status = data.status end
    
    update_data.updated_at = Global.getCurrentTimestamp()
    
    return self:update(hospital_id, update_data)
end

-- Get hospital with parsed JSON fields
function HospitalModel:getWithParsedData(hospital_id)
    local hospital = self:find(hospital_id)
    if not hospital then
        return nil
    end
    
    -- Parse JSON fields
    if hospital.specialties then
        local ok, parsed = pcall(cJson.decode, hospital.specialties)
        if ok then hospital.specialties = parsed end
    end
    
    if hospital.services then
        local ok, parsed = pcall(cJson.decode, hospital.services)
        if ok then hospital.services = parsed end
    end
    
    if hospital.facilities then
        local ok, parsed = pcall(cJson.decode, hospital.facilities)
        if ok then hospital.facilities = parsed end
    end
    
    if hospital.operating_hours then
        local ok, parsed = pcall(cJson.decode, hospital.operating_hours)
        if ok then hospital.operating_hours = parsed end
    end
    
    return hospital
end

-- Search hospitals by criteria
function HospitalModel:search(criteria)
    local conditions = {}
    local params = {}
    
    if criteria.name then
        table.insert(conditions, "name ILIKE ?")
        table.insert(params, "%" .. criteria.name .. "%")
    end
    
    if criteria.type then
        table.insert(conditions, "type = ?")
        table.insert(params, criteria.type)
    end
    
    if criteria.city then
        table.insert(conditions, "city ILIKE ?")
        table.insert(params, "%" .. criteria.city .. "%")
    end
    
    if criteria.state then
        table.insert(conditions, "state ILIKE ?")
        table.insert(params, "%" .. criteria.state .. "%")
    end
    
    if criteria.emergency_services ~= nil then
        table.insert(conditions, "emergency_services = ?")
        table.insert(params, criteria.emergency_services)
    end
    
    if criteria.status then
        table.insert(conditions, "status = ?")
        table.insert(params, criteria.status)
    end
    
    local where_clause = ""
    if #conditions > 0 then
        where_clause = "WHERE " .. table.concat(conditions, " AND ")
    end
    
    local query = "SELECT * FROM hospitals " .. where_clause .. " ORDER BY name ASC"
    
    return self.db.select(query, unpack(params))
end

-- Get hospitals by type
function HospitalModel:getByType(type)
    return self:select("WHERE type = ? ORDER BY name ASC", type)
end

-- Get active hospitals
function HospitalModel:getActive()
    return self:select("WHERE status = 'active' ORDER BY name ASC")
end

-- Get hospital statistics
function HospitalModel:getStatistics(hospital_id)
    local db = require("lapis.db")
    
    local stats = {}
    
    -- Total patients
    local patient_count = db.select("SELECT COUNT(*) as count FROM patients WHERE hospital_id = ?", hospital_id)
    stats.total_patients = patient_count[1] and patient_count[1].count or 0
    
    -- Active patients
    local active_patients = db.select("SELECT COUNT(*) as count FROM patients WHERE hospital_id = ? AND status = 'active'", hospital_id)
    stats.active_patients = active_patients[1] and active_patients[1].count or 0
    
    -- Total staff
    local staff_count = db.select("SELECT COUNT(*) as count FROM hospital_staff WHERE hospital_id = ?", hospital_id)
    stats.total_staff = staff_count[1] and staff_count[1].count or 0
    
    -- Active staff
    local active_staff = db.select("SELECT COUNT(*) as count FROM hospital_staff WHERE hospital_id = ? AND status = 'active'", hospital_id)
    stats.active_staff = active_staff[1] and active_staff[1].count or 0
    
    -- Recent admissions (last 30 days)
    local recent_admissions = db.select("SELECT COUNT(*) as count FROM patients WHERE hospital_id = ? AND admission_date >= CURRENT_DATE - INTERVAL '30 days'", hospital_id)
    stats.recent_admissions = recent_admissions[1] and recent_admissions[1].count or 0
    
    return stats
end

return HospitalModel
