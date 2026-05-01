local CareLogModel = require "models.CareLogModel"
local Global = require "helper.global"
local cJson = require("cjson")

local CareLogQueries = {}

local VALID_FIELDS = {
    uuid = true, patient_id = true, care_plan_id = true, staff_id = true,
    log_type = true, log_date = true, log_time = true, shift = true,
    summary = true, details = true,
    medication_name = true, medication_dose = true, medication_administered = true,
    medication_refused_reason = true,
    meal_type = true, intake_amount = true, fluid_intake_ml = true,
    mood = true, behaviour_notes = true,
    personal_care_type = true, assistance_level = true,
    incident_type = true, incident_severity = true, action_taken = true,
    follow_up_required = true, follow_up_notes = true,
    status = true, reviewed_by = true, reviewed_at = true,
}

function CareLogQueries.create(params)
    local filtered = {}
    for field in pairs(VALID_FIELDS) do
        if params[field] ~= nil then filtered[field] = params[field] end
    end
    if not filtered.uuid then filtered.uuid = Global.generateUUID() end
    if filtered.details and type(filtered.details) == "table" then
        filtered.details = cJson.encode(filtered.details)
    end
    -- Convert boolean strings
    if filtered.medication_administered ~= nil and type(filtered.medication_administered) == "string" then
        filtered.medication_administered = filtered.medication_administered == "true"
    end
    if filtered.follow_up_required ~= nil and type(filtered.follow_up_required) == "string" then
        filtered.follow_up_required = filtered.follow_up_required == "true"
    end
    return CareLogModel:create(filtered, { returning = "*" })
end

function CareLogQueries.all(params)
    local page = params.page or 1
    local perPage = params.perPage or 20

    local conditions = {}
    if params.patient_id then
        table.insert(conditions, "patient_id = " .. tonumber(params.patient_id))
    end
    if params.log_type then
        table.insert(conditions, "log_type = '" .. params.log_type .. "'")
    end
    if params.log_date then
        table.insert(conditions, "log_date = '" .. params.log_date .. "'")
    end
    if params.shift then
        table.insert(conditions, "shift = '" .. params.shift .. "'")
    end
    if params.staff_id then
        table.insert(conditions, "staff_id = " .. tonumber(params.staff_id))
    end

    local where_clause = ""
    if #conditions > 0 then
        where_clause = "where " .. table.concat(conditions, " and ")
    end

    local valid_order = { id = true, log_date = true, log_time = true, log_type = true, created_at = true }
    local orderField, orderDir = Global.sanitizeOrderBy(params.orderBy, params.orderDir, valid_order, "log_date", "desc")
    local order_clause = " order by " .. orderField .. " " .. orderDir

    local paginated = CareLogModel:paginated(where_clause .. order_clause, { per_page = perPage })
    return {
        data = paginated:get_page(page),
        total = paginated:total_items()
    }
end

function CareLogQueries.show(id)
    return CareLogModel:find({ uuid = id })
end

function CareLogQueries.update(id, params)
    local record = CareLogModel:find({ uuid = id })
    if not record then return nil end

    local filtered = {}
    for field in pairs(VALID_FIELDS) do
        if field ~= "uuid" and field ~= "patient_id" and params[field] ~= nil then
            filtered[field] = params[field]
        end
    end
    if filtered.details and type(filtered.details) == "table" then
        filtered.details = cJson.encode(filtered.details)
    end
    return record:update(filtered, { returning = "*" })
end

function CareLogQueries.destroy(id)
    local record = CareLogModel:find({ uuid = id })
    if not record then return nil end
    return record:delete()
end

function CareLogQueries.getIncidents(patient_id)
    return CareLogModel:getIncidents(patient_id)
end

return CareLogQueries
