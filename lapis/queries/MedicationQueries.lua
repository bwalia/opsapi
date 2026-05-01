local MedicationModel = require "models.MedicationModel"
local Global = require "helper.global"
local cJson = require("cjson")

local MedicationQueries = {}

local VALID_FIELDS = {
    uuid = true, patient_id = true, care_plan_id = true, name = true,
    generic_name = true, dosage = true, unit = true, route = true,
    frequency = true, schedule_times = true, instructions = true,
    purpose = true, prescriber = true, pharmacy = true,
    start_date = true, end_date = true, is_prn = true, max_daily_doses = true,
    side_effects = true, interactions = true, allergies_check = true,
    status = true, discontinued_reason = true, notes = true,
}

local JSON_FIELDS = { "schedule_times", "side_effects", "interactions" }

local function encode_json_fields(filtered)
    for _, field in ipairs(JSON_FIELDS) do
        if filtered[field] and type(filtered[field]) == "table" then
            filtered[field] = cJson.encode(filtered[field])
        end
    end
end

function MedicationQueries.create(params)
    local filtered = {}
    for field in pairs(VALID_FIELDS) do
        if params[field] ~= nil then filtered[field] = params[field] end
    end
    if not filtered.uuid then filtered.uuid = Global.generateUUID() end
    encode_json_fields(filtered)
    if filtered.is_prn ~= nil and type(filtered.is_prn) == "string" then
        filtered.is_prn = filtered.is_prn == "true"
    end
    if filtered.allergies_check ~= nil and type(filtered.allergies_check) == "string" then
        filtered.allergies_check = filtered.allergies_check == "true"
    end
    return MedicationModel:create(filtered, { returning = "*" })
end

function MedicationQueries.all(params)
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

    local valid_order = { id = true, name = true, start_date = true, status = true, created_at = true }
    local orderField, orderDir = Global.sanitizeOrderBy(params.orderBy, params.orderDir, valid_order, "name", "asc")
    local order_clause = " order by " .. orderField .. " " .. orderDir

    local paginated = MedicationModel:paginated(where_clause .. order_clause, { per_page = perPage })
    return {
        data = paginated:get_page(page),
        total = paginated:total_items()
    }
end

function MedicationQueries.show(id)
    return MedicationModel:find({ uuid = id })
end

function MedicationQueries.update(id, params)
    local record = MedicationModel:find({ uuid = id })
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

function MedicationQueries.destroy(id)
    local record = MedicationModel:find({ uuid = id })
    if not record then return nil end
    return record:delete()
end

function MedicationQueries.getActive(patient_id)
    return MedicationModel:getActive(patient_id)
end

function MedicationQueries.getPRN(patient_id)
    return MedicationModel:getPRN(patient_id)
end

return MedicationQueries
