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
            SELECT
                dr.id, dr.uuid, dr.order_id, dr.delivery_partner_id,
                dr.request_type, dr.status, dr.proposed_fee, dr.message,
                dr.response_message, dr.created_at, dr.updated_at,
                dr.expires_at, dr.responded_at,
                -- Order fields with 'order_' prefix
                o.id as order_id_fk,
                o.uuid as order_uuid,
                o.order_number as order_order_number,
                o.total_amount as order_total_amount,
                o.shipping_address as order_shipping_address,
                o.status as order_status,
                -- Delivery partner fields with 'dp_' prefix
                dp.id as dp_id,
                dp.uuid as dp_uuid,
                dp.company_name as dp_company_name,
                dp.contact_person_name as dp_contact_person_name,
                dp.contact_person_phone as dp_contact_person_phone,
                dp.rating as dp_rating,
                dp.total_deliveries as dp_total_deliveries,
                dp.service_type as dp_service_type,
                dp.vehicle_types as dp_vehicle_types
            FROM delivery_requests dr
            INNER JOIN orders o ON dr.order_id = o.id
            INNER JOIN delivery_partners dp ON dr.delivery_partner_id = dp.id
            WHERE o.store_id = ?
            AND dr.status = ?
            AND (dr.expires_at IS NULL OR dr.expires_at > NOW())
            ORDER BY dr.created_at DESC
            LIMIT ? OFFSET ?
        ]]
    else
        query = [[
            SELECT
                dr.id, dr.uuid, dr.order_id, dr.delivery_partner_id,
                dr.request_type, dr.status, dr.proposed_fee, dr.message,
                dr.response_message, dr.created_at, dr.updated_at,
                dr.expires_at, dr.responded_at,
                -- Order fields with 'order_' prefix
                o.id as order_id_fk,
                o.uuid as order_uuid,
                o.order_number as order_order_number,
                o.total_amount as order_total_amount,
                o.shipping_address as order_shipping_address,
                o.status as order_status,
                -- Delivery partner fields with 'dp_' prefix
                dp.id as dp_id,
                dp.uuid as dp_uuid,
                dp.company_name as dp_company_name,
                dp.contact_person_name as dp_contact_person_name,
                dp.contact_person_phone as dp_contact_person_phone,
                dp.rating as dp_rating,
                dp.total_deliveries as dp_total_deliveries,
                dp.service_type as dp_service_type,
                dp.vehicle_types as dp_vehicle_types
            FROM delivery_requests dr
            INNER JOIN orders o ON dr.order_id = o.id
            INNER JOIN delivery_partners dp ON dr.delivery_partner_id = dp.id
            WHERE o.store_id = ?
            AND (dr.expires_at IS NULL OR dr.expires_at > NOW())
            ORDER BY dr.created_at DESC
            LIMIT ? OFFSET ?
        ]]
    end

    -- Execute query
    local results
    if status then
        results = db.query(query, store_id, status, limit, offset)
    else
        results = db.query(query, store_id, limit, offset)
    end

    -- Transform flat results into nested structure
    local requests = {}
    for _, row in ipairs(results) do
        -- Parse shipping address JSON
        local shipping_address_json = {}
        if row.order_shipping_address and row.order_shipping_address ~= "" then
            local ok, parsed = pcall(function()
                return require("cjson").decode(row.order_shipping_address)
            end)
            if ok and parsed then
                shipping_address_json = parsed
            end
        end

        -- Parse vehicle types if it's a JSON array string
        local vehicle_types = {}
        if row.dp_vehicle_types and row.dp_vehicle_types ~= "" then
            local ok, parsed = pcall(function()
                return require("cjson").decode(row.dp_vehicle_types)
            end)
            if ok and type(parsed) == "table" then
                vehicle_types = parsed
            elseif type(row.dp_vehicle_types) == "string" then
                -- If it's a plain string, split by comma
                for vehicle in string.gmatch(row.dp_vehicle_types, "[^,]+") do
                    table.insert(vehicle_types, vehicle:match("^%s*(.-)%s*$")) -- trim whitespace
                end
            end
        end

        table.insert(requests, {
            -- Request fields
            id = row.id,
            uuid = row.uuid,
            order_id = row.order_id,
            delivery_partner_id = row.delivery_partner_id,
            request_type = row.request_type,
            status = row.status,
            proposed_fee = row.proposed_fee,
            message = row.message,
            response_message = row.response_message,
            created_at = row.created_at,
            updated_at = row.updated_at,
            expires_at = row.expires_at,
            responded_at = row.responded_at,

            -- Nested order object
            order = {
                id = row.order_id_fk,
                uuid = row.order_uuid,
                order_number = row.order_order_number,
                total_amount = row.order_total_amount,
                shipping_address = row.order_shipping_address,
                status = row.order_status,
                -- Extract address fields from shipping_address JSON
                delivery_address = shipping_address_json.address1 or "",
                delivery_city = shipping_address_json.city or "",
                delivery_state = shipping_address_json.state or ""
            },

            -- Nested delivery_partner object
            delivery_partner = {
                id = row.dp_id,
                uuid = row.dp_uuid,
                company_name = row.dp_company_name,
                contact_person_name = row.dp_contact_person_name,
                contact_person_phone = row.dp_contact_person_phone,
                rating = tonumber(row.dp_rating) or 0,
                total_deliveries = tonumber(row.dp_total_deliveries) or 0,
                service_type = row.dp_service_type,
                vehicle_types = vehicle_types
            }
        })
    end

    return requests
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
