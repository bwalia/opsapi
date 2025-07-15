local StoreproductModel = require "models.StoreproductModel"
local StoreModel = require "models.StoreModel"
local Global = require "helper.global"

local StoreproductQueries = {}

function StoreproductQueries.create(params)
    if not params.uuid then
        params.uuid = Global.generateUUID()
    end
    if not params.inventory_quantity then
        params.inventory_quantity = 0
    end
    if not params.track_inventory then
        params.track_inventory = true
    end
    return StoreproductModel:create(params, { returning = "*" })
end

function StoreproductQueries.updateInventory(product_uuid, quantity_change)
    local product = StoreproductModel:find({ uuid = product_uuid })
    if not product then
        return nil, "Product not found"
    end
    
    if product.track_inventory then
        local new_quantity = product.inventory_quantity + quantity_change
        if new_quantity < 0 then
            return nil, "Insufficient inventory. Available: " .. product.inventory_quantity
        end
        product:update({ inventory_quantity = new_quantity })
    end
    
    return product, nil
end

function StoreproductQueries.checkInventory(product_uuid, required_quantity)
    local product = StoreproductModel:find({ uuid = product_uuid })
    if not product then
        return false, "Product not found"
    end
    
    if product.track_inventory and product.inventory_quantity < required_quantity then
        return false, "Insufficient inventory. Available: " .. product.inventory_quantity
    end
    
    return true, nil
end

function StoreproductQueries.all(params)
    local page, perPage, orderField, orderDir =
        params.page or 1, params.perPage or 10, params.orderBy or 'id', params.orderDir or 'desc'
    
    local paginated = StoreproductModel:paginated("order by " .. orderField .. " " .. orderDir, {
        per_page = perPage
    })
    
    local products = paginated:get_page(page)
    for i, product in ipairs(products) do
        product:get_store()
        product:get_category()
    end
    
    return {
        data = products,
        total = paginated:total_items()
    }
end

-- Get products by store
function StoreproductQueries.getByStore(store_id, params)
    local page, perPage, orderField, orderDir =
        params.page or 1, params.perPage or 10, params.orderBy or 'id', params.orderDir or 'desc'
    
    local paginated = StoreproductModel:paginated("WHERE store_id = ? ORDER BY " .. orderField .. " " .. orderDir, {
        per_page = perPage
    }, store_id)
    
    local products = paginated:get_page(page)
    for i, product in ipairs(products) do
        product:get_category()
    end
    
    return {
        data = products,
        total = paginated:total_items()
    }
end

-- Get products by store and category
function StoreproductQueries.getByStoreAndCategory(store_id, category_id, params)
    local page, perPage, orderField, orderDir =
        params.page or 1, params.perPage or 10, params.orderBy or 'id', params.orderDir or 'desc'
    
    local paginated = StoreproductModel:paginated("WHERE store_id = ? AND category_id = ? ORDER BY " .. orderField .. " " .. orderDir, {
        per_page = perPage
    }, store_id, category_id)
    
    return {
        data = paginated:get_page(page),
        total = paginated:total_items()
    }
end

function StoreproductQueries.show(id)
    return StoreproductModel:find({ uuid = id })
end

function StoreproductQueries.update(id, params)
    local record = StoreproductModel:find({ uuid = id })
    if not record then return nil end
    params.id = record.id
    return record:update(params, { returning = "*" })
end

function StoreproductQueries.destroy(id)
    local record = StoreproductModel:find({ uuid = id })
    if not record then return nil end
    return record:delete()
end

return StoreproductQueries
