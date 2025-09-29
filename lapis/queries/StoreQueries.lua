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

    -- Handle tax rate validation and conversion
    if params.tax_rate then
        local tax_rate = tonumber(params.tax_rate)
        if not tax_rate or tax_rate < 0 or tax_rate > 100 then
            error("Tax rate must be a number between 0 and 100")
        end
        params.tax_rate = tax_rate / 100  -- Convert percentage to decimal (10% -> 0.1)
    else
        params.tax_rate = 0.1  -- Default 10%
    end

    -- Handle shipping configuration
    if params.shipping_enabled == nil then
        params.shipping_enabled = false
    end

    if params.shipping_enabled then
        -- Validate shipping rate
        if params.shipping_flat_rate then
            local shipping_rate = tonumber(params.shipping_flat_rate)
            if not shipping_rate or shipping_rate < 0 then
                error("Shipping rate must be a positive number")
            end
            params.shipping_flat_rate = shipping_rate
        else
            params.shipping_flat_rate = 0
        end

        -- Validate free shipping threshold
        if params.free_shipping_threshold then
            local threshold = tonumber(params.free_shipping_threshold)
            if not threshold or threshold < 0 then
                error("Free shipping threshold must be a positive number")
            end
            params.free_shipping_threshold = threshold
        else
            params.free_shipping_threshold = 0
        end
    else
        -- If shipping is disabled, set shipping values to 0
        params.shipping_flat_rate = 0
        params.free_shipping_threshold = 0
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

function StoreQueries.showByUUID(uuid)
    return StoreModel:find({ uuid = uuid })
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

    -- Delete associated products, categories, and orders
    record:get_products():delete_all()
    record:get_categories():delete_all()
    record:get_orders():delete_all()

    return record:delete()
end

return StoreQueries
