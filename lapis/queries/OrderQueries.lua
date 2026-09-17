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
    local page = params.page or 1
    local perPage = params.perPage or 10

    -- Validate ORDER BY to prevent SQL injection
    local valid_fields = { id = true, order_number = true, status = true, total_price = true, financial_status = true, fulfillment_status = true, created_at = true, updated_at = true }
    local orderField, orderDir = Global.sanitizeOrderBy(params.orderBy, params.orderDir, valid_fields, "id", "desc")

    local paginated = OrderModel:paginated("WHERE store_id = ? ORDER BY " .. orderField .. " " .. orderDir, {
        per_page = perPage
    }, store_id)

    return {
        data = paginated:get_page(page),
        total = paginated:total_items()
    }
end

function OrderQueries.all(params)
    local page = params.page or 1
    local perPage = params.perPage or 10

    -- Validate ORDER BY to prevent SQL injection
    local valid_fields = { id = true, order_number = true, status = true, total_price = true, financial_status = true, fulfillment_status = true, created_at = true, updated_at = true }
    local orderField, orderDir = Global.sanitizeOrderBy(params.orderBy, params.orderDir, valid_fields, "id", "desc")

    -- Defensive tenant scope: this helper is not currently routed, but if it is
    -- wired up it must not return every tenant's orders. Callers pass namespace_id.
    local paginated
    if params.namespace_id then
        paginated = OrderModel:paginated("where namespace_id = ? order by " .. orderField .. " " .. orderDir,
            tonumber(params.namespace_id), { per_page = perPage })
    else
        paginated = OrderModel:paginated("order by " .. orderField .. " " .. orderDir, { per_page = perPage })
    end

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
