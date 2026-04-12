local PatientAuditLogModel = require "models.PatientAuditLogModel"
local Global = require "helper.global"
local cJson = require("cjson")

local PatientAuditLogQueries = {}

function PatientAuditLogQueries.log(params)
    return PatientAuditLogModel:log(params)
end

function PatientAuditLogQueries.all(params)
    local page = params.page or 1
    local perPage = params.perPage or 50

    local conditions = {}
    if params.patient_id then
        table.insert(conditions, "patient_id = " .. tonumber(params.patient_id))
    end
    if params.user_id then
        table.insert(conditions, "user_id = " .. tonumber(params.user_id))
    end
    if params.action then
        table.insert(conditions, "action = '" .. params.action .. "'")
    end
    if params.resource_type then
        table.insert(conditions, "resource_type = '" .. params.resource_type .. "'")
    end
    if params.date_from then
        table.insert(conditions, "created_at >= '" .. params.date_from .. "'")
    end
    if params.date_to then
        table.insert(conditions, "created_at <= '" .. params.date_to .. "'")
    end

    local where_clause = ""
    if #conditions > 0 then
        where_clause = "where " .. table.concat(conditions, " and ")
    end

    local valid_order = { id = true, action = true, resource_type = true, created_at = true }
    local orderField, orderDir = Global.sanitizeOrderBy(params.orderBy, params.orderDir, valid_order, "created_at", "desc")
    local order_clause = " order by " .. orderField .. " " .. orderDir

    local paginated = PatientAuditLogModel:paginated(where_clause .. order_clause, { per_page = perPage })
    return {
        data = paginated:get_page(page),
        total = paginated:total_items()
    }
end

function PatientAuditLogQueries.show(id)
    return PatientAuditLogModel:find({ uuid = id })
end

function PatientAuditLogQueries.getAccessHistory(patient_id)
    return PatientAuditLogModel:getAccessHistory(patient_id)
end

function PatientAuditLogQueries.getFailedAccess(patient_id)
    return PatientAuditLogModel:getFailedAccess(patient_id)
end

return PatientAuditLogQueries
