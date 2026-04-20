--[[
  Patient Service

  Business logic layer for patient management.
  Handles validation, complex queries, and cross-cutting concerns.
]]

local db = require("lapis.db")

local PatientService = {}

--- Validate patient data before create/update
-- @param params table Patient fields
-- @return boolean, string|nil Valid, error message
function PatientService.validate(params)
    if not params.first_name or #params.first_name < 1 then
        return false, "First name is required"
    end
    if not params.last_name or #params.last_name < 1 then
        return false, "Last name is required"
    end
    if params.email and not params.email:match("^[%w%.%-]+@[%w%.%-]+%.%w+$") then
        return false, "Invalid email format"
    end
    if params.nhs_number and not params.nhs_number:match("^%d%d%d%s?%d%d%d%s?%d%d%d%d$") then
        return false, "NHS number must be 10 digits"
    end
    return true, nil
end

--- Get patient statistics for a namespace
-- @param namespace_id number
-- @return table Statistics
function PatientService.getStats(namespace_id)
    local stats = db.select([[
        COUNT(*) as total_patients,
        COUNT(*) FILTER (WHERE status = 'active') as active_patients,
        COUNT(*) FILTER (WHERE status = 'inactive') as inactive_patients,
        COUNT(*) FILTER (WHERE admitted_at IS NOT NULL AND discharged_at IS NULL) as currently_admitted
        FROM hpm_patients WHERE namespace_id = ?
    ]], namespace_id)

    return stats[1] or { total_patients = 0, active_patients = 0, inactive_patients = 0, currently_admitted = 0 }
end

--- Search patients by multiple criteria
-- @param namespace_id number
-- @param query string Search query
-- @param limit number Max results
-- @return table List of matching patients
function PatientService.search(namespace_id, query, limit)
    limit = limit or 10
    local escaped = db.escape_literal("%" .. query .. "%")

    return db.select([[
        * FROM hpm_patients
        WHERE namespace_id = ?
        AND (
            first_name ILIKE ]] .. escaped .. [[ OR
            last_name ILIKE ]] .. escaped .. [[ OR
            nhs_number ILIKE ]] .. escaped .. [[ OR
            email ILIKE ]] .. escaped .. [[
        )
        ORDER BY last_name, first_name
        LIMIT ?
    ]], namespace_id, limit)
end

--- Admit a patient
-- @param patient_id number
-- @param namespace_id number
-- @return boolean, string Success, message
function PatientService.admit(patient_id, namespace_id)
    local patients = db.select("* FROM hpm_patients WHERE id = ? AND namespace_id = ? LIMIT 1",
        patient_id, namespace_id)

    if #patients == 0 then
        return false, "Patient not found"
    end

    if patients[1].admitted_at and not patients[1].discharged_at then
        return false, "Patient is already admitted"
    end

    db.update("hpm_patients", {
        admitted_at = db.raw("NOW()"),
        discharged_at = db.NULL,
        status = "active",
        updated_at = db.raw("NOW()"),
    }, { id = patient_id })

    return true, "Patient admitted"
end

--- Discharge a patient
-- @param patient_id number
-- @param namespace_id number
-- @return boolean, string Success, message
function PatientService.discharge(patient_id, namespace_id)
    local patients = db.select("* FROM hpm_patients WHERE id = ? AND namespace_id = ? LIMIT 1",
        patient_id, namespace_id)

    if #patients == 0 then
        return false, "Patient not found"
    end

    if not patients[1].admitted_at or patients[1].discharged_at then
        return false, "Patient is not currently admitted"
    end

    db.update("hpm_patients", {
        discharged_at = db.raw("NOW()"),
        updated_at = db.raw("NOW()"),
    }, { id = patient_id })

    return true, "Patient discharged"
end

return PatientService
