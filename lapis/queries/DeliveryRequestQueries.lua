local db = require("lapis.db")
local Global = require("helper.global")

local DeliveryRequestQueries = {}

-- Create delivery request
function DeliveryRequestQueries.create(params)
    local uuid = Global.generateUUID()

    -- Set expiry time (24 hours from now by default)
    local expires_at = params.expires_at or db.format_date(os.time() + 86400)

    local request = db.insert("delivery_requests", {
        uuid = uuid,
        order_id = params.order_id,
        delivery_partner_id = params.delivery_partner_id,
        request_type = params.request_type or 'seller_to_partner',
        status = 'pending',
        proposed_fee = params.proposed_fee,
        message = params.message,
        expires_at = expires_at,
        created_at = db.format_date(),
        updated_at = db.format_date()
    })

    return request
end

-- Get request by uuid
function DeliveryRequestQueries.findByUuid(uuid)
    local result = db.select("* FROM delivery_requests WHERE uuid = ?", uuid)
    return result and result[1] or nil
end

-- Get requests for order
function DeliveryRequestQueries.findByOrderId(order_id, status)
    if status then
        return db.select("* FROM delivery_requests WHERE order_id = ? AND status = ? ORDER BY created_at DESC", order_id, status)
    else
        return db.select("* FROM delivery_requests WHERE order_id = ? ORDER BY created_at DESC", order_id)
    end
end

-- Get requests for delivery partner
function DeliveryRequestQueries.findByPartnerId(delivery_partner_id, status, limit, offset)
    limit = limit or 20
    offset = offset or 0

    local query
    if status then
        query = [[
            SELECT dr.*, o.order_number, o.total_amount, o.shipping_address,
                   s.name as store_name, s.slug as store_slug, s.contact_phone as store_phone
            FROM delivery_requests dr
            INNER JOIN orders o ON dr.order_id = o.id
            INNER JOIN stores s ON o.store_id = s.id
            WHERE dr.delivery_partner_id = ?
            AND dr.status = ?
            AND (dr.expires_at IS NULL OR dr.expires_at > NOW())
            ORDER BY dr.created_at DESC
            LIMIT ? OFFSET ?
        ]]
        return db.query(query, delivery_partner_id, status, limit, offset)
    else
        query = [[
            SELECT dr.*, o.order_number, o.total_amount, o.shipping_address,
                   s.name as store_name, s.slug as store_slug, s.contact_phone as store_phone
            FROM delivery_requests dr
            INNER JOIN orders o ON dr.order_id = o.id
            INNER JOIN stores s ON o.store_id = s.id
            WHERE dr.delivery_partner_id = ?
            AND (dr.expires_at IS NULL OR dr.expires_at > NOW())
            ORDER BY dr.created_at DESC
            LIMIT ? OFFSET ?
        ]]
        return db.query(query, delivery_partner_id, limit, offset)
    end
end

-- Get pending requests for store orders
function DeliveryRequestQueries.findByStoreId(store_id, status, limit, offset)
    limit = limit or 20
    offset = offset or 0

    local query
    if status then
        query = [[
            SELECT dr.*, o.order_number, o.total_amount,
                   dp.company_name, dp.rating, dp.total_deliveries, dp.contact_person_phone
            FROM delivery_requests dr
            INNER JOIN orders o ON dr.order_id = o.id
            INNER JOIN delivery_partners dp ON dr.delivery_partner_id = dp.id
            WHERE o.store_id = ?
            AND dr.status = ?
            AND (dr.expires_at IS NULL OR dr.expires_at > NOW())
            ORDER BY dr.created_at DESC
            LIMIT ? OFFSET ?
        ]]
        return db.query(query, store_id, status, limit, offset)
    else
        query = [[
            SELECT dr.*, o.order_number, o.total_amount,
                   dp.company_name, dp.rating, dp.total_deliveries, dp.contact_person_phone
            FROM delivery_requests dr
            INNER JOIN orders o ON dr.order_id = o.id
            INNER JOIN delivery_partners dp ON dr.delivery_partner_id = dp.id
            WHERE o.store_id = ?
            AND (dr.expires_at IS NULL OR dr.expires_at > NOW())
            ORDER BY dr.created_at DESC
            LIMIT ? OFFSET ?
        ]]
        return db.query(query, store_id, limit, offset)
    end
end

-- Update request status
function DeliveryRequestQueries.updateStatus(id, status, response_message)
    db.update("delivery_requests", {
        status = status,
        response_message = response_message,
        responded_at = db.format_date(),
        updated_at = db.format_date()
    }, "id = ?", id)

    local result = db.select("* FROM delivery_requests WHERE id = ?", id)
    return result and result[1] or nil
end

-- Check if request exists
function DeliveryRequestQueries.exists(order_id, delivery_partner_id)
    local result = db.select([[
        * FROM delivery_requests
        WHERE order_id = ?
        AND delivery_partner_id = ?
        AND status = 'pending'
        LIMIT 1
    ]], order_id, delivery_partner_id)

    return result and #result > 0
end

-- Expire old requests
function DeliveryRequestQueries.expireOldRequests()
    db.query([[
        UPDATE delivery_requests
        SET status = 'expired', updated_at = NOW()
        WHERE status = 'pending'
        AND expires_at IS NOT NULL
        AND expires_at < NOW()
    ]])
end

-- Get request count for order
function DeliveryRequestQueries.getCountByOrder(order_id, status)
    local query
    if status then
        query = "SELECT COUNT(*) as count FROM delivery_requests WHERE order_id = ? AND status = ?"
        local result = db.query(query, order_id, status)
        return result and result[1] and result[1].count or 0
    else
        query = "SELECT COUNT(*) as count FROM delivery_requests WHERE order_id = ?"
        local result = db.query(query, order_id)
        return result and result[1] and result[1].count or 0
    end
end

-- Alias methods for compatibility with routes
function DeliveryRequestQueries.getByDeliveryPartner(delivery_partner_id, status)
    return DeliveryRequestQueries.findByPartnerId(delivery_partner_id, status)
end

function DeliveryRequestQueries.getByStore(store_id, status)
    return DeliveryRequestQueries.findByStoreId(store_id, status)
end

-- Accept request
function DeliveryRequestQueries.accept(request_id, response_message)
    return DeliveryRequestQueries.updateStatus(request_id, 'accepted', response_message)
end

-- Reject request
function DeliveryRequestQueries.reject(request_id, response_message)
    return DeliveryRequestQueries.updateStatus(request_id, 'rejected', response_message)
end

return DeliveryRequestQueries
