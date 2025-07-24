local CategoryModel = require "models.CategoryModel"
local StoreQueries = require "queries.StoreQueries"
local Global = require "helper.global"

local CategoryQueries = {}

function CategoryQueries.create(params)
    if not params.uuid then
        params.uuid = Global.generateUUID()
    end
    if params.store_id then
        -- Ensure store_id is valid
        local store = StoreQueries.show(params.store_id)
        if store then
            params.store_id = store.id
        end
    end
    return CategoryModel:create(params, { returning = "*" })
end

function CategoryQueries.all(params)
    local page, perPage, orderField, orderDir =
        params.page or 1, params.perPage or 10, params.orderBy or 'id', params.orderDir or 'desc'
    
    local where_clause = ""
    local where_params = {}
    
    if params.store_id and params.store_id ~= "" then
        local store = StoreQueries.showByUUID(params.store_id)
        if store then
            where_clause = "WHERE store_id = ?"
            table.insert(where_params, store.id)
        else
            -- Return empty if store not found
            return { data = {}, total = 0 }
        end
    end
    
    local paginated = CategoryModel:paginated(
        where_clause .. " order by " .. orderField .. " " .. orderDir,
         unpack(where_params),{
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

    -- Delete associated products
    record:get_products():delete_all()

    return record:delete()
end

return CategoryQueries
