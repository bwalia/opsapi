local FamilyMemberModel = require "models.FamilyMemberModel"
local Global = require "helper.global"
local cJson = require("cjson")

local FamilyMemberQueries = {}

local VALID_FIELDS = {
    uuid = true, patient_id = true, user_id = true, first_name = true,
    last_name = true, relationship = true, is_next_of_kin = true,
    is_emergency_contact = true, is_power_of_attorney = true,
    phone = true, email = true, address = true,
    preferred_contact_method = true, preferred_language = true,
    notification_preferences = true, can_make_decisions = true,
    decision_scope = true, verified = true, verified_at = true,
    verified_by = true, status = true, notes = true,
}

local JSON_FIELDS = { "notification_preferences", "decision_scope" }

local function encode_json_fields(filtered)
    for _, field in ipairs(JSON_FIELDS) do
        if filtered[field] and type(filtered[field]) == "table" then
            filtered[field] = cJson.encode(filtered[field])
        end
    end
end

local function convert_booleans(filtered)
    local bool_fields = { "is_next_of_kin", "is_emergency_contact", "is_power_of_attorney", "can_make_decisions", "verified" }
    for _, field in ipairs(bool_fields) do
        if filtered[field] ~= nil and type(filtered[field]) == "string" then
            filtered[field] = filtered[field] == "true"
        end
    end
end

function FamilyMemberQueries.create(params)
    local filtered = {}
    for field in pairs(VALID_FIELDS) do
        if params[field] ~= nil then filtered[field] = params[field] end
    end
    if not filtered.uuid then filtered.uuid = Global.generateUUID() end
    encode_json_fields(filtered)
    convert_booleans(filtered)
    return FamilyMemberModel:create(filtered, { returning = "*" })
end

function FamilyMemberQueries.all(params)
    local page = params.page or 1
    local perPage = params.perPage or 20

    local conditions = {}
    if params.patient_id then
        table.insert(conditions, "patient_id = " .. tonumber(params.patient_id))
    end
    if params.status then
        table.insert(conditions, "status = '" .. params.status .. "'")
    end

    local where_clause = ""
    if #conditions > 0 then
        where_clause = "where " .. table.concat(conditions, " and ")
    end

    local valid_order = { id = true, first_name = true, last_name = true, relationship = true, created_at = true }
    local orderField, orderDir = Global.sanitizeOrderBy(params.orderBy, params.orderDir, valid_order, "last_name", "asc")
    local order_clause = " order by " .. orderField .. " " .. orderDir

    local paginated = FamilyMemberModel:paginated(where_clause .. order_clause, { per_page = perPage })
    return {
        data = paginated:get_page(page),
        total = paginated:total_items()
    }
end

function FamilyMemberQueries.show(id)
    return FamilyMemberModel:find({ uuid = id })
end

function FamilyMemberQueries.update(id, params)
    local record = FamilyMemberModel:find({ uuid = id })
    if not record then return nil end

    local filtered = {}
    for field in pairs(VALID_FIELDS) do
        if field ~= "uuid" and field ~= "patient_id" and params[field] ~= nil then
            filtered[field] = params[field]
        end
    end
    encode_json_fields(filtered)
    convert_booleans(filtered)
    return record:update(filtered, { returning = "*" })
end

function FamilyMemberQueries.destroy(id)
    local record = FamilyMemberModel:find({ uuid = id })
    if not record then return nil end
    return record:delete()
end

function FamilyMemberQueries.getNextOfKin(patient_id)
    return FamilyMemberModel:getNextOfKin(patient_id)
end

function FamilyMemberQueries.getEmergencyContacts(patient_id)
    return FamilyMemberModel:getEmergencyContacts(patient_id)
end

return FamilyMemberQueries
