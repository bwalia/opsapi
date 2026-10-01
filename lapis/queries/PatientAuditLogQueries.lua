local PatientAuditLogModel = require "models.PatientAuditLogModel"
local Global = require "helper.global"
local cJson = require("cjson")

local PatientAuditLogQueries = {}

function PatientAuditLogQueries.log(params)
    return PatientAuditLogModel:log(params)
end

function PatientAuditLogQueries.all(params)
    local page = Global.pageParam(params.page)
    local perPage = Global.perPageParam(params.perPage, 50, 100)

    local conditions, values = {}, {} -- values bind to the ? placeholders
    if params.patient_id then
        table.insert(conditions, "patient_id = ?")
        table.insert(values, tonumber(params.patient_id) or -1) -- not a number: matches nothing
    end
    if params.user_id then
        table.insert(conditions, "user_id = ?")
        table.insert(values, tonumber(params.user_id) or -1) -- not a number: matches nothing
    end
    if params.action then
        table.insert(conditions, "action = ?")
        table.insert(values, tostring(params.action))
    end
    if params.resource_type then
        table.insert(conditions, "resource_type = ?")
        table.insert(values, tostring(params.resource_type))
    end
    if params.date_from then
        table.insert(conditions, "created_at >= ?")
        table.insert(values, tostring(params.date_from))
    end
    if params.date_to then
        table.insert(conditions, "created_at <= ?")
        table.insert(values, tostring(params.date_to))
    end

    local where_clause = ""
    if #conditions > 0 then
        where_clause = "where " .. table.concat(conditions, " and ")
    end

    local valid_order = { id = true, action = true, resource_type = true, created_at = true }
    local orderField, orderDir = Global.sanitizeOrderBy(params.orderBy, params.orderDir, valid_order, "created_at", "desc")
    local order_clause = " order by " .. orderField .. " " .. orderDir

    values[#values + 1] = { per_page = perPage }
    local paginated = PatientAuditLogModel:paginated(where_clause .. order_clause, unpack(values))
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
