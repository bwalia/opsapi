local OrderitemModel = require "models.OrderitemModel"
local Global = require "helper.global"

local OrderitemQueries = {}

function OrderitemQueries.create(params)
    if not params.uuid then
        params.uuid = Global.generateUUID()
    end
    
    -- Validate required fields
    if not params.order_id or not params.product_id or not params.quantity or not params.price then
        error("Missing required fields: order_id, product_id, quantity, price")
    end
    
    -- Calculate total if not provided
    if not params.total then
        params.total = params.quantity * params.price
    end
    
    -- Update inventory if product tracks inventory
    local StoreproductQueries = require "queries.StoreproductQueries"
    local product, err = StoreproductQueries.updateInventory(params.product_id, -params.quantity)
    if err then
        error(err)
    end
    
    return OrderitemModel:create(params, { returning = "*" })
end

function OrderitemQueries.getByOrder(order_id, params)
    local page, perPage, orderField, orderDir =
        params.page or 1, params.perPage or 50, params.orderBy or 'id', params.orderDir or 'asc'
    
    local paginated = OrderitemModel:paginated("WHERE order_id = ? ORDER BY " .. orderField .. " " .. orderDir, {
        per_page = perPage
    }, order_id)
    
    return {
        data = paginated:get_page(page),
        total = paginated:total_items()
    }
end

function OrderitemQueries.all(params)
    local page, perPage, orderField, orderDir =
        params.page or 1, params.perPage or 10, params.orderBy or 'id', params.orderDir or 'desc'
    
    local paginated = OrderitemModel:paginated("order by " .. orderField .. " " .. orderDir, {
        per_page = perPage
    })
    
    return {
        data = paginated:get_page(page),
        total = paginated:total_items()
    }
end

function OrderitemQueries.show(id)
    return OrderitemModel:find({ uuid = id })
end

function OrderitemQueries.update(id, params)
    local record = OrderitemModel:find({ uuid = id })
    if not record then return nil end
    params.id = record.id
    return record:update(params, { returning = "*" })
end

function OrderitemQueries.destroy(id)
    local record = OrderitemModel:find({ uuid = id })
    if not record then return nil end
    return record:delete()
end

return OrderitemQueries
