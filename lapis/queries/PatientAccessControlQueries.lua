local PatientAccessControlModel = require "models.PatientAccessControlModel"
local Global = require "helper.global"
local cJson = require("cjson")

local PatientAccessControlQueries = {}

local VALID_FIELDS = {
    uuid = true, patient_id = true, granted_to = true, granted_to_user_id = true,
    role = true, relationship = true, access_level = true, scope = true,
    data_categories = true, granted_by = true, granted_by_user_id = true,
    share_token = true, token_expires_at = true, requires_2fa = true,
    ip_whitelist = true, expires_at = true, status = true,
    consent_given = true, consent_date = true, notes = true,
}

local JSON_FIELDS = { "scope", "data_categories", "ip_whitelist" }

local function encode_json_fields(filtered)
    for _, field in ipairs(JSON_FIELDS) do
        if filtered[field] and type(filtered[field]) == "table" then
            filtered[field] = cJson.encode(filtered[field])
        end
    end
end

function PatientAccessControlQueries.create(params)
    local filtered = {}
    for field in pairs(VALID_FIELDS) do
        if params[field] ~= nil then filtered[field] = params[field] end
    end
    if not filtered.uuid then filtered.uuid = Global.generateUUID() end
    encode_json_fields(filtered)
    if filtered.requires_2fa ~= nil and type(filtered.requires_2fa) == "string" then
        filtered.requires_2fa = filtered.requires_2fa == "true"
    end
    if filtered.consent_given ~= nil and type(filtered.consent_given) == "string" then
        filtered.consent_given = filtered.consent_given == "true"
    end
    return PatientAccessControlModel:create(filtered, { returning = "*" })
end

function PatientAccessControlQueries.all(params)
    local page = params.page or 1
    local perPage = params.perPage or 20

    local conditions = {}
    if params.patient_id then
        table.insert(conditions, "patient_id = " .. tonumber(params.patient_id))
    end
    if params.granted_to then
        table.insert(conditions, "granted_to = '" .. params.granted_to .. "'")
    end
    if params.status then
        table.insert(conditions, "status = '" .. params.status .. "'")
    end
    if params.role then
        table.insert(conditions, "role = '" .. params.role .. "'")
    end

    local where_clause = ""
    if #conditions > 0 then
        where_clause = "where " .. table.concat(conditions, " and ")
    end

    local valid_order = { id = true, granted_to = true, role = true, expires_at = true, created_at = true }
    local orderField, orderDir = Global.sanitizeOrderBy(params.orderBy, params.orderDir, valid_order, "created_at", "desc")
    local order_clause = " order by " .. orderField .. " " .. orderDir

    local paginated = PatientAccessControlModel:paginated(where_clause .. order_clause, { per_page = perPage })
    return {
        data = paginated:get_page(page),
        total = paginated:total_items()
    }
end

function PatientAccessControlQueries.show(id)
    return PatientAccessControlModel:find({ uuid = id })
end

function PatientAccessControlQueries.update(id, params)
    local record = PatientAccessControlModel:find({ uuid = id })
    if not record then return nil end

    local filtered = {}
    for field in pairs(VALID_FIELDS) do
        if field ~= "uuid" and field ~= "patient_id" and params[field] ~= nil then
            filtered[field] = params[field]
        end
    end
    encode_json_fields(filtered)
    return record:update(filtered, { returning = "*" })
end

function PatientAccessControlQueries.revoke(id, reason)
    return PatientAccessControlModel:revokeAccess(id, reason)
end

function PatientAccessControlQueries.checkAccess(patient_id, granted_to, scope_item)
    return PatientAccessControlModel:checkAccess(patient_id, granted_to, scope_item)
end

function PatientAccessControlQueries.getByShareToken(token)
    local results = PatientAccessControlModel:getByShareToken(token)
    return results and results[1] or nil
end

function PatientAccessControlQueries.destroy(id)
    local record = PatientAccessControlModel:find({ uuid = id })
    if not record then return nil end
    return record:delete()
end

return PatientAccessControlQueries
