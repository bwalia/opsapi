local StoreModel = require "models.StoreModel"
local Global = require "helper.global"

local StoreQueries = {}

function StoreQueries.create(params)
    -- Validate required fields
    if not params.name or params.name == "" then
        error("Store name is required")
    end
    if not params.user_id then
        error("User ID is required for store creation")
    end
    
    -- Generate UUID if not provided
    if not params.uuid then
        params.uuid = Global.generateUUID()
    end
    
    -- Set default status
    if not params.status then
        params.status = 'active'
    end
    
    -- Sanitize slug
    if params.slug then
        params.slug = string.lower(params.slug):gsub("[^a-z0-9-]", "-"):gsub("-+", "-")
    else
        params.slug = string.lower(params.name):gsub("[^a-z0-9-]", "-"):gsub("-+", "-")
    end
    
    return StoreModel:create(params, { returning = "*" })
end

-- Get stores by user (store owner)
function StoreQueries.getByUser(user_id, params)
    local page, perPage, orderField, orderDir =
        params.page or 1, params.perPage or 10, params.orderBy or 'id', params.orderDir or 'desc'
    
    local paginated = StoreModel:paginated("WHERE user_id = ? ORDER BY " .. orderField .. " " .. orderDir, user_id, {
        per_page = perPage
    })
    
    return {
        data = paginated:get_page(page),
        total = paginated:total_items()
    }
end

function StoreQueries.all(params)
    local page, perPage, orderField, orderDir =
        params.page or 1, params.perPage or 10, params.orderBy or 'id', params.orderDir or 'desc'
    
    local paginated = StoreModel:paginated("order by " .. orderField .. " " .. orderDir, {
        per_page = perPage
    })
    
    return {
        data = paginated:get_page(page),
        total = paginated:total_items()
    }
end

function StoreQueries.show(id)
    local store = StoreModel:find({ uuid = id })
    if store then
        store:get_owner()
        store:get_products()
        store:get_categories()
    end
    return store
end

-- Show store with owner verification
function StoreQueries.showByOwner(id, user_id)
    local store = StoreModel:find({ uuid = id, user_id = user_id })
    if store then
        store:get_products()
        store:get_categories()
    end
    return store
end

function StoreQueries.update(id, params)
    local record = StoreModel:find({ uuid = id })
    if not record then return nil end
    params.id = record.id
    return record:update(params, { returning = "*" })
end

function StoreQueries.destroy(id)
    local record = StoreModel:find({ uuid = id })
    if not record then return nil end
    return record:delete()
end

return StoreQueries
