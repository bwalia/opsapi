local CategoryModel = require "models.CategoryModel"
local Global = require "helper.global"

local CategoryQueries = {}

function CategoryQueries.create(params)
    if not params.uuid then
        params.uuid = Global.generateUUID()
    end
    return CategoryModel:create(params, { returning = "*" })
end

function CategoryQueries.all(params)
    local page, perPage, orderField, orderDir =
        params.page or 1, params.perPage or 10, params.orderBy or 'id', params.orderDir or 'desc'
    
    local paginated = CategoryModel:paginated("order by " .. orderField .. " " .. orderDir, {
        per_page = perPage
    })
    
    return {
        data = paginated:get_page(page),
        total = paginated:total_items()
    }
end

function CategoryQueries.show(id)
    return CategoryModel:find({ uuid = id })
end

function CategoryQueries.update(id, params)
    local record = CategoryModel:find({ uuid = id })
    if not record then return nil end
    params.id = record.id
    return record:update(params, { returning = "*" })
end

function CategoryQueries.destroy(id)
    local record = CategoryModel:find({ uuid = id })
    if not record then return nil end
    return record:delete()
end

return CategoryQueries
