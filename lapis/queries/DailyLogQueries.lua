local DailyLogModel = require "models.DailyLogModel"
local Global = require "helper.global"
local cJson = require("cjson")

local DailyLogQueries = {}

local VALID_FIELDS = {
    uuid = true, patient_id = true, log_date = true, shift = true, recorded_by = true,
    sleep_quality = true, sleep_hours = true, sleep_notes = true,
    breakfast_intake = true, lunch_intake = true, dinner_intake = true,
    snack_intake = true, fluid_intake_ml = true, nutrition_notes = true,
    medications_given = true, medications_refused = true, medication_notes = true,
    activities = true, mobility_level = true, exercise_completed = true, activity_notes = true,
    overall_mood = true, mood_changes = true, behavioural_incidents = true,
    social_interactions = true,
    personal_care_completed = true, continence_notes = true,
    general_wellbeing = true, pain_level = true, weight = true, concerns = true,
    family_notified = true, family_visit = true, family_visit_notes = true, status = true,
}

local JSON_FIELDS = {
    "medications_given", "medications_refused", "activities",
    "mood_changes", "behavioural_incidents", "social_interactions",
    "personal_care_completed"
}

local function encode_json_fields(filtered)
    for _, field in ipairs(JSON_FIELDS) do
        if filtered[field] and type(filtered[field]) == "table" then
            filtered[field] = cJson.encode(filtered[field])
        end
    end
end

function DailyLogQueries.create(params)
    local filtered = {}
    for field in pairs(VALID_FIELDS) do
        if params[field] ~= nil then filtered[field] = params[field] end
    end
    if not filtered.uuid then filtered.uuid = Global.generateUUID() end
    encode_json_fields(filtered)
    -- Convert booleans
    local bool_fields = { "exercise_completed", "family_notified", "family_visit" }
    for _, f in ipairs(bool_fields) do
        if filtered[f] ~= nil and type(filtered[f]) == "string" then
            filtered[f] = filtered[f] == "true"
        end
    end
    return DailyLogModel:create(filtered, { returning = "*" })
end

function DailyLogQueries.all(params)
    local page = params.page or 1
    local perPage = params.perPage or 20

    local conditions = {}
    if params.patient_id then
        table.insert(conditions, "patient_id = " .. tonumber(params.patient_id))
    end
    if params.log_date then
        table.insert(conditions, "log_date = '" .. params.log_date .. "'")
    end
    if params.shift then
        table.insert(conditions, "shift = '" .. params.shift .. "'")
    end

    local where_clause = ""
    if #conditions > 0 then
        where_clause = "where " .. table.concat(conditions, " and ")
    end

    local valid_order = { id = true, log_date = true, shift = true, overall_mood = true, created_at = true }
    local orderField, orderDir = Global.sanitizeOrderBy(params.orderBy, params.orderDir, valid_order, "log_date", "desc")
    local order_clause = " order by " .. orderField .. " " .. orderDir

    local paginated = DailyLogModel:paginated(where_clause .. order_clause, { per_page = perPage })
    return {
        data = paginated:get_page(page),
        total = paginated:total_items()
    }
end

function DailyLogQueries.show(id)
    return DailyLogModel:find({ uuid = id })
end

function DailyLogQueries.update(id, params)
    local record = DailyLogModel:find({ uuid = id })
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

function DailyLogQueries.destroy(id)
    local record = DailyLogModel:find({ uuid = id })
    if not record then return nil end
    return record:delete()
end

function DailyLogQueries.getToday(patient_id)
    return DailyLogModel:getToday(patient_id)
end

return DailyLogQueries
