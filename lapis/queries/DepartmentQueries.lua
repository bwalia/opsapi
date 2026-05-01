local DepartmentModel = require "models.DepartmentModel"
local Global = require "helper.global"
local cJson = require("cjson")

local DepartmentQueries = {}

local VALID_FIELDS = {
    uuid = true, hospital_id = true, name = true, code = true,
    description = true, head_of_department = true, phone = true,
    email = true, floor = true, capacity = true, specialties = true,
    operating_hours = true, status = true,
}

function DepartmentQueries.create(params)
    local filtered = {}
    for field in pairs(VALID_FIELDS) do
        if params[field] ~= nil then filtered[field] = params[field] end
    end
    if not filtered.uuid then filtered.uuid = Global.generateUUID() end
    if filtered.specialties and type(filtered.specialties) == "table" then
        filtered.specialties = cJson.encode(filtered.specialties)
    end
    if filtered.operating_hours and type(filtered.operating_hours) == "table" then
        filtered.operating_hours = cJson.encode(filtered.operating_hours)
    end
    return DepartmentModel:create(filtered, { returning = "*" })
end

function DepartmentQueries.all(params)
    local page = params.page or 1
    local perPage = params.perPage or 20
    local hospital_id = params.hospital_id

    local where_clause = ""
    if hospital_id then
        where_clause = "where hospital_id = " .. tonumber(hospital_id)
    end

    local valid_order = { id = true, name = true, code = true, created_at = true }
    local orderField, orderDir = Global.sanitizeOrderBy(params.orderBy, params.orderDir, valid_order, "name", "asc")
    local order_clause = " order by " .. orderField .. " " .. orderDir

    local paginated = DepartmentModel:paginated(where_clause .. order_clause, { per_page = perPage })
    return {
        data = paginated:get_page(page),
        total = paginated:total_items()
    }
end

function DepartmentQueries.show(id)
    return DepartmentModel:find({ uuid = id })
end

function DepartmentQueries.update(id, params)
    local record = DepartmentModel:find({ uuid = id })
    if not record then return nil end

    local filtered = {}
    for field in pairs(VALID_FIELDS) do
        if field ~= "uuid" and field ~= "hospital_id" and params[field] ~= nil then
            filtered[field] = params[field]
        end
    end
    if filtered.specialties and type(filtered.specialties) == "table" then
        filtered.specialties = cJson.encode(filtered.specialties)
    end
    if filtered.operating_hours and type(filtered.operating_hours) == "table" then
        filtered.operating_hours = cJson.encode(filtered.operating_hours)
    end
    return record:update(filtered, { returning = "*" })
end

function DepartmentQueries.destroy(id)
    local record = DepartmentModel:find({ uuid = id })
    if not record then return nil end
    return record:delete()
end

return DepartmentQueries
