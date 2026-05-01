local DementiaAssessmentModel = require "models.DementiaAssessmentModel"
local Global = require "helper.global"
local cJson = require("cjson")

local DementiaAssessmentQueries = {}

local VALID_FIELDS = {
    uuid = true, patient_id = true, assessor = true, assessment_type = true,
    assessment_date = true, score = true, max_score = true, severity_level = true,
    cognitive_domains = true, behavioural_symptoms = true, functional_abilities = true,
    wandering_risk = true, fall_risk = true, communication_ability = true,
    recognition_ability = true, sleep_pattern = true, recommendations = true,
    memory_prompts = true, routine_preferences = true, triggers_to_avoid = true,
    calming_strategies = true, next_assessment_date = true, status = true, notes = true,
}

local JSON_FIELDS = {
    "cognitive_domains", "behavioural_symptoms", "functional_abilities",
    "recognition_ability", "sleep_pattern", "recommendations",
    "memory_prompts", "routine_preferences", "triggers_to_avoid", "calming_strategies"
}

local function encode_json_fields(filtered)
    for _, field in ipairs(JSON_FIELDS) do
        if filtered[field] and type(filtered[field]) == "table" then
            filtered[field] = cJson.encode(filtered[field])
        end
    end
end

function DementiaAssessmentQueries.create(params)
    local filtered = {}
    for field in pairs(VALID_FIELDS) do
        if params[field] ~= nil then filtered[field] = params[field] end
    end
    if not filtered.uuid then filtered.uuid = Global.generateUUID() end
    encode_json_fields(filtered)
    return DementiaAssessmentModel:create(filtered, { returning = "*" })
end

function DementiaAssessmentQueries.all(params)
    local page = params.page or 1
    local perPage = params.perPage or 20

    local conditions = {}
    if params.patient_id then
        table.insert(conditions, "patient_id = " .. tonumber(params.patient_id))
    end
    if params.assessment_type then
        table.insert(conditions, "assessment_type = '" .. params.assessment_type .. "'")
    end
    if params.severity_level then
        table.insert(conditions, "severity_level = '" .. params.severity_level .. "'")
    end

    local where_clause = ""
    if #conditions > 0 then
        where_clause = "where " .. table.concat(conditions, " and ")
    end

    local valid_order = { id = true, assessment_date = true, assessment_type = true, severity_level = true, created_at = true }
    local orderField, orderDir = Global.sanitizeOrderBy(params.orderBy, params.orderDir, valid_order, "assessment_date", "desc")
    local order_clause = " order by " .. orderField .. " " .. orderDir

    local paginated = DementiaAssessmentModel:paginated(where_clause .. order_clause, { per_page = perPage })
    return {
        data = paginated:get_page(page),
        total = paginated:total_items()
    }
end

function DementiaAssessmentQueries.show(id)
    return DementiaAssessmentModel:find({ uuid = id })
end

function DementiaAssessmentQueries.update(id, params)
    local record = DementiaAssessmentModel:find({ uuid = id })
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

function DementiaAssessmentQueries.destroy(id)
    local record = DementiaAssessmentModel:find({ uuid = id })
    if not record then return nil end
    return record:delete()
end

function DementiaAssessmentQueries.getLatest(patient_id)
    return DementiaAssessmentModel:getLatest(patient_id)
end

function DementiaAssessmentQueries.getHighRiskWandering()
    return DementiaAssessmentModel:getHighRiskWandering()
end

function DementiaAssessmentQueries.getDueForReassessment()
    return DementiaAssessmentModel:getDueForReassessment()
end

return DementiaAssessmentQueries
