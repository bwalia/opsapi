local PatientAlertModel = require "models.PatientAlertModel"
local Global = require "helper.global"
local cJson = require("cjson")

local PatientAlertQueries = {}

local VALID_FIELDS = {
    uuid = true, patient_id = true, hospital_id = true, alert_type = true,
    severity = true, title = true, message = true, details = true,
    triggered_by = true, triggered_rule = true, assigned_to = true,
    escalation_level = true, escalated_to = true,
    acknowledged_by = true, acknowledged_at = true,
    resolved_by = true, resolved_at = true, resolution_notes = true,
    notify_family = true, family_notified_at = true,
    notification_channels = true, status = true,
}

local JSON_FIELDS = { "details", "triggered_rule", "notification_channels" }

local function encode_json_fields(filtered)
    for _, field in ipairs(JSON_FIELDS) do
        if filtered[field] and type(filtered[field]) == "table" then
            filtered[field] = cJson.encode(filtered[field])
        end
    end
end

function PatientAlertQueries.create(params)
    local filtered = {}
    for field in pairs(VALID_FIELDS) do
        if params[field] ~= nil then filtered[field] = params[field] end
    end
    if not filtered.uuid then filtered.uuid = Global.generateUUID() end
    encode_json_fields(filtered)
    if filtered.notify_family ~= nil and type(filtered.notify_family) == "string" then
        filtered.notify_family = filtered.notify_family == "true"
    end
    return PatientAlertModel:create(filtered, { returning = "*" })
end

function PatientAlertQueries.all(params)
    local page = params.page or 1
    local perPage = params.perPage or 20

    local conditions = {}
    if params.patient_id then
        table.insert(conditions, "patient_id = " .. tonumber(params.patient_id))
    end
    if params.hospital_id then
        table.insert(conditions, "hospital_id = " .. tonumber(params.hospital_id))
    end
    if params.alert_type then
        table.insert(conditions, "alert_type = '" .. params.alert_type .. "'")
    end
    if params.severity then
        table.insert(conditions, "severity = '" .. params.severity .. "'")
    end
    if params.status then
        table.insert(conditions, "status = '" .. params.status .. "'")
    end
    if params.assigned_to then
        table.insert(conditions, "assigned_to = '" .. params.assigned_to .. "'")
    end

    local where_clause = ""
    if #conditions > 0 then
        where_clause = "where " .. table.concat(conditions, " and ")
    end

    local valid_order = { id = true, alert_type = true, severity = true, status = true, created_at = true }
    local orderField, orderDir = Global.sanitizeOrderBy(params.orderBy, params.orderDir, valid_order, "created_at", "desc")
    local order_clause = " order by " .. orderField .. " " .. orderDir

    local paginated = PatientAlertModel:paginated(where_clause .. order_clause, { per_page = perPage })
    return {
        data = paginated:get_page(page),
        total = paginated:total_items()
    }
end

function PatientAlertQueries.show(id)
    return PatientAlertModel:find({ uuid = id })
end

function PatientAlertQueries.update(id, params)
    local record = PatientAlertModel:find({ uuid = id })
    if not record then return nil end

    local filtered = {}
    for field in pairs(VALID_FIELDS) do
        if field ~= "uuid" and field ~= "patient_id" and field ~= "hospital_id" and params[field] ~= nil then
            filtered[field] = params[field]
        end
    end
    encode_json_fields(filtered)
    return record:update(filtered, { returning = "*" })
end

function PatientAlertQueries.acknowledge(id, acknowledged_by)
    local record = PatientAlertModel:find({ uuid = id })
    if not record then return nil end
    return PatientAlertModel:acknowledge(record.id, acknowledged_by)
end

function PatientAlertQueries.resolve(id, resolved_by, notes)
    local record = PatientAlertModel:find({ uuid = id })
    if not record then return nil end
    return PatientAlertModel:resolve(record.id, resolved_by, notes)
end

function PatientAlertQueries.getActive(hospital_id)
    return PatientAlertModel:getActive(hospital_id)
end

function PatientAlertQueries.getCritical(hospital_id)
    return PatientAlertModel:getCritical(hospital_id)
end

function PatientAlertQueries.destroy(id)
    local record = PatientAlertModel:find({ uuid = id })
    if not record then return nil end
    return record:delete()
end

return PatientAlertQueries
