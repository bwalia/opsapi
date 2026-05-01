local WardModel = require "models.WardModel"
local Global = require "helper.global"
local cJson = require("cjson")

local WardQueries = {}

local VALID_FIELDS = {
    uuid = true, hospital_id = true, department_id = true, name = true,
    code = true, ward_type = true, floor = true, capacity = true,
    current_occupancy = true, nurse_station_phone = true,
    visiting_hours = true, restrictions = true, status = true,
}

function WardQueries.create(params)
    local filtered = {}
    for field in pairs(VALID_FIELDS) do
        if params[field] ~= nil then filtered[field] = params[field] end
    end
    if not filtered.uuid then filtered.uuid = Global.generateUUID() end
    if filtered.visiting_hours and type(filtered.visiting_hours) == "table" then
        filtered.visiting_hours = cJson.encode(filtered.visiting_hours)
    end
    if filtered.restrictions and type(filtered.restrictions) == "table" then
        filtered.restrictions = cJson.encode(filtered.restrictions)
    end
    return WardModel:create(filtered, { returning = "*" })
end

function WardQueries.all(params)
    local page = params.page or 1
    local perPage = params.perPage or 20
    local hospital_id = params.hospital_id

    local where_clause = ""
    if hospital_id then
        where_clause = "where hospital_id = " .. tonumber(hospital_id)
        if params.department_id then
            where_clause = where_clause .. " and department_id = " .. tonumber(params.department_id)
        end
    end

    local valid_order = { id = true, name = true, code = true, ward_type = true, created_at = true }
    local orderField, orderDir = Global.sanitizeOrderBy(params.orderBy, params.orderDir, valid_order, "name", "asc")
    local order_clause = " order by " .. orderField .. " " .. orderDir

    local paginated = WardModel:paginated(where_clause .. order_clause, { per_page = perPage })
    return {
        data = paginated:get_page(page),
        total = paginated:total_items()
    }
end

function WardQueries.show(id)
    return WardModel:find({ uuid = id })
end

function WardQueries.update(id, params)
    local record = WardModel:find({ uuid = id })
    if not record then return nil end

    local filtered = {}
    for field in pairs(VALID_FIELDS) do
        if field ~= "uuid" and field ~= "hospital_id" and params[field] ~= nil then
            filtered[field] = params[field]
        end
    end
    if filtered.visiting_hours and type(filtered.visiting_hours) == "table" then
        filtered.visiting_hours = cJson.encode(filtered.visiting_hours)
    end
    if filtered.restrictions and type(filtered.restrictions) == "table" then
        filtered.restrictions = cJson.encode(filtered.restrictions)
    end
    return record:update(filtered, { returning = "*" })
end

function WardQueries.destroy(id)
    local record = WardModel:find({ uuid = id })
    if not record then return nil end
    return record:delete()
end

return WardQueries
