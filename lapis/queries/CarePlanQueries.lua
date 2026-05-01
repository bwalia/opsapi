local CarePlanModel = require "models.CarePlanModel"
local Global = require "helper.global"
local cJson = require("cjson")

local CarePlanQueries = {}

local VALID_FIELDS = {
    uuid = true, patient_id = true, hospital_id = true, plan_type = true,
    title = true, description = true, goals = true, interventions = true,
    medication_schedule = true, daily_routines = true, risk_assessments = true,
    dietary_requirements = true, mobility_aids = true, communication_needs = true,
    created_by = true, approved_by = true, review_date = true,
    start_date = true, end_date = true, status = true, priority = true, notes = true,
}

local JSON_FIELDS = {
    "goals", "interventions", "medication_schedule", "daily_routines",
    "risk_assessments", "dietary_requirements", "mobility_aids", "communication_needs"
}

local function encode_json_fields(filtered)
    for _, field in ipairs(JSON_FIELDS) do
        if filtered[field] and type(filtered[field]) == "table" then
            filtered[field] = cJson.encode(filtered[field])
        end
    end
end

function CarePlanQueries.create(params)
    local filtered = {}
    for field in pairs(VALID_FIELDS) do
        if params[field] ~= nil then filtered[field] = params[field] end
    end
    if not filtered.uuid then filtered.uuid = Global.generateUUID() end
    encode_json_fields(filtered)
    return CarePlanModel:create(filtered, { returning = "*" })
end

function CarePlanQueries.all(params)
    local page = params.page or 1
    local perPage = params.perPage or 20

    local conditions = {}
    if params.patient_id then
        table.insert(conditions, "patient_id = " .. tonumber(params.patient_id))
    end
    if params.hospital_id then
        table.insert(conditions, "hospital_id = " .. tonumber(params.hospital_id))
    end
    if params.status then
        table.insert(conditions, "status = '" .. params.status .. "'")
    end
    if params.plan_type then
        table.insert(conditions, "plan_type = '" .. params.plan_type .. "'")
    end

    local where_clause = ""
    if #conditions > 0 then
        where_clause = "where " .. table.concat(conditions, " and ")
    end

    local valid_order = { id = true, title = true, plan_type = true, priority = true, start_date = true, review_date = true, created_at = true }
    local orderField, orderDir = Global.sanitizeOrderBy(params.orderBy, params.orderDir, valid_order, "created_at", "desc")
    local order_clause = " order by " .. orderField .. " " .. orderDir

    local paginated = CarePlanModel:paginated(where_clause .. order_clause, { per_page = perPage })
    return {
        data = paginated:get_page(page),
        total = paginated:total_items()
    }
end

function CarePlanQueries.show(id)
    return CarePlanModel:find({ uuid = id })
end

function CarePlanQueries.update(id, params)
    local record = CarePlanModel:find({ uuid = id })
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

function CarePlanQueries.destroy(id)
    local record = CarePlanModel:find({ uuid = id })
    if not record then return nil end
    return record:delete()
end

function CarePlanQueries.getDueForReview()
    return CarePlanModel:getDueForReview()
end

return CarePlanQueries
