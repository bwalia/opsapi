local ProductModel = require "models.ProductModel"
local Validation = require "helper.validations"
local Global = require "helper.global"

local ProductQueries = {}

function ProductQueries.create(params)
    -- Add validation here if needed
    -- Validation.createProduct(params)
    
    local data = params
    if not data.uuid then
        data.uuid = Global.generateUUID()
    end
    
    return ProductModel:create(data, {
        returning = "*"
    })
end

function ProductQueries.all(params)
    local page, perPage, orderField, orderDir =
        params.page or 1, params.perPage or 10, params.orderBy or 'id', params.orderDir or 'desc'

    local paginated = ProductModel:paginated("order by " .. orderField .. " " .. orderDir, {
        per_page = perPage
    })
    
    local records = paginated:get_page(page)
    
    -- Load relations if needed
    -- for i, record in ipairs(records) do
    --     record:get_relation_name()
    -- end
    
    return {
        data = records,
        total = paginated:total_items()
    }
end

function ProductQueries.show(id)
    local record = ProductModel:find({
        uuid = id
    })
    
    -- Load relations if needed
    -- if record then
    --     record:get_relation_name()
    -- end
    
    return record
end

function ProductQueries.update(id, params)
    local record = ProductModel:find({
        uuid = id
    })
    
    if not record then
        return nil
    end
    
    params.id = record.id
    return record:update(params, {
        returning = "*"
    })
end

function ProductQueries.destroy(id)
    local record = ProductModel:find({
        uuid = id
    })
    
    if not record then
        return nil
    end
    
    return record:delete()
end

return ProductQueries
