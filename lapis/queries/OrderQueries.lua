local OrderModel = require "models.OrderModel"
local Global = require "helper.global"

local OrderQueries = {}

function OrderQueries.create(params)
    if not params.uuid then
        params.uuid = Global.generateUUID()
    end
    if not params.order_number then
        params.order_number = "ORD-" .. os.time() .. "-" .. math.random(1000, 9999)
    end
    if not params.status then
        params.status = "pending"
    end
    if not params.financial_status then
        params.financial_status = "pending"
    end
    if not params.fulfillment_status then
        params.fulfillment_status = "unfulfilled"
    end
    
    return OrderModel:create(params, { returning = "*" })
end

function OrderQueries.getByStore(store_id, params)
    local page, perPage, orderField, orderDir =
        params.page or 1, params.perPage or 10, params.orderBy or 'id', params.orderDir or 'desc'
    
    local paginated = OrderModel:paginated("WHERE store_id = ? ORDER BY " .. orderField .. " " .. orderDir, {
        per_page = perPage
    }, store_id)
    
    return {
        data = paginated:get_page(page),
        total = paginated:total_items()
    }
end

function OrderQueries.all(params)
    local page, perPage, orderField, orderDir =
        params.page or 1, params.perPage or 10, params.orderBy or 'id', params.orderDir or 'desc'
    
    local paginated = OrderModel:paginated("order by " .. orderField .. " " .. orderDir, {
        per_page = perPage
    })
    
    return {
        data = paginated:get_page(page),
        total = paginated:total_items()
    }
end

function OrderQueries.show(id)
    return OrderModel:find({ uuid = id })
end

function OrderQueries.update(id, params)
    local record = OrderModel:find({ uuid = id })
    if not record then return nil end
    params.id = record.id
    return record:update(params, { returning = "*" })
end

function OrderQueries.destroy(id)
    local record = OrderModel:find({ uuid = id })
    if not record then return nil end
    return record:delete()
end

return OrderQueries
