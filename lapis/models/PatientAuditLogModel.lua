local Model = require("lapis.db.model").Model
local cJson = require("cjson")
local Global = require "helper.global"

local PatientAuditLogModel = Model:extend("patient_audit_logs", {
    timestamp = false -- audit logs only have created_at, no updates
})

function PatientAuditLogModel:log(data)
    return self:create({
        uuid = Global.generateUUID(),
        patient_id = data.patient_id,
        user_id = data.user_id,
        action = data.action,
        resource_type = data.resource_type,
        resource_id = data.resource_id,
        resource_uuid = data.resource_uuid,
        changes = data.changes and cJson.encode(data.changes) or nil,
        ip_address = data.ip_address,
        user_agent = data.user_agent,
        session_id = data.session_id,
        access_context = data.access_context or "direct",
        consent_reference = data.consent_reference,
        data_categories_accessed = data.data_categories_accessed and cJson.encode(data.data_categories_accessed) or nil,
        request_id = data.request_id,
        status = data.status or "success",
        failure_reason = data.failure_reason,
        created_at = Global.getCurrentTimestamp()
    }, { returning = "*" })
end

function PatientAuditLogModel:getByPatient(patient_id, filters)
    local where = "WHERE patient_id = ?"
    local params = { patient_id }

    if filters then
        if filters.action then
            where = where .. " AND action = ?"
            table.insert(params, filters.action)
        end
        if filters.resource_type then
            where = where .. " AND resource_type = ?"
            table.insert(params, filters.resource_type)
        end
        if filters.user_id then
            where = where .. " AND user_id = ?"
            table.insert(params, filters.user_id)
        end
        if filters.date_from then
            where = where .. " AND created_at >= ?"
            table.insert(params, filters.date_from)
        end
        if filters.date_to then
            where = where .. " AND created_at <= ?"
            table.insert(params, filters.date_to)
        end
    end

    where = where .. " ORDER BY created_at DESC"
    return self:select(where, unpack(params))
end

function PatientAuditLogModel:getByUser(user_id)
    return self:select("WHERE user_id = ? ORDER BY created_at DESC", user_id)
end

function PatientAuditLogModel:getAccessHistory(patient_id)
    return self:select(
        "WHERE patient_id = ? AND action = 'view' ORDER BY created_at DESC",
        patient_id
    )
end

function PatientAuditLogModel:getFailedAccess(patient_id)
    return self:select(
        "WHERE patient_id = ? AND status = 'denied' ORDER BY created_at DESC",
        patient_id
    )
end

return PatientAuditLogModel
