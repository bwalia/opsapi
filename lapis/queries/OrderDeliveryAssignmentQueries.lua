local db = require("lapis.db")
local Global = require("helper.global")

local OrderDeliveryAssignmentQueries = {}

-- Create delivery assignment
function OrderDeliveryAssignmentQueries.create(params)
    local uuid = Global.generateUUID()
    local tracking_number = "TRK-" .. string.upper(string.sub(Global.generateUUID(), 1, 10))

    local assignment = db.insert("order_delivery_assignments", {
        uuid = uuid,
        order_id = params.order_id,
        delivery_partner_id = params.delivery_partner_id,
        assignment_type = params.assignment_type or 'seller_assigned',
        status = params.status or 'pending',
        delivery_fee = params.delivery_fee,
        pickup_address = params.pickup_address,
        delivery_address = params.delivery_address,
        pickup_instructions = params.pickup_instructions,
        delivery_instructions = params.delivery_instructions,
        estimated_pickup_time = params.estimated_pickup_time,
        estimated_delivery_time = params.estimated_delivery_time,
        distance_km = params.distance_km,
        tracking_number = tracking_number,
        notes = params.notes,
        created_at = db.format_date(),
        updated_at = db.format_date()
    })

    return assignment
end

-- Get assignment by order_id
function OrderDeliveryAssignmentQueries.findByOrderId(order_id)
    local result = db.select("* FROM order_delivery_assignments WHERE order_id = ?", order_id)
    return result and result[1] or nil
end

-- Get assignment by uuid
function OrderDeliveryAssignmentQueries.findByUuid(uuid)
    local result = db.select("* FROM order_delivery_assignments WHERE uuid = ?", uuid)
    return result and result[1] or nil
end

-- Get assignment by tracking number
function OrderDeliveryAssignmentQueries.findByTrackingNumber(tracking_number)
    local result = db.select("* FROM order_delivery_assignments WHERE tracking_number = ?", tracking_number)
    return result and result[1] or nil
end

-- Get assignments for delivery partner
function OrderDeliveryAssignmentQueries.findByPartnerId(delivery_partner_id, status, limit, offset)
    limit = limit or 20
    offset = offset or 0

    local query

    -- Handle special status filters
    if status == "active" then
        -- "active" means any assignment that is not completed or failed
        query = [[
            SELECT oda.*, o.order_number, o.total_amount, o.customer_id, o.status as order_status,
                   o.shipping_address, o.delivery_latitude, o.delivery_longitude,
                   s.name as store_name, s.slug as store_slug, s.contact_phone as store_phone
            FROM order_delivery_assignments oda
            INNER JOIN orders o ON oda.order_id = o.id
            INNER JOIN stores s ON o.store_id = s.id
            WHERE oda.delivery_partner_id = ?
            AND oda.status IN ('pending', 'accepted', 'picked_up', 'in_transit')
            ORDER BY oda.created_at DESC
            LIMIT ? OFFSET ?
        ]]
        return db.query(query, delivery_partner_id, limit, offset)
    elseif status == "completed" then
        -- "completed" means delivered or failed
        query = [[
            SELECT oda.*, o.order_number, o.total_amount, o.customer_id, o.status as order_status,
                   o.shipping_address, o.delivery_latitude, o.delivery_longitude,
                   s.name as store_name, s.slug as store_slug, s.contact_phone as store_phone
            FROM order_delivery_assignments oda
            INNER JOIN orders o ON oda.order_id = o.id
            INNER JOIN stores s ON o.store_id = s.id
            WHERE oda.delivery_partner_id = ?
            AND oda.status IN ('delivered', 'failed', 'cancelled')
            ORDER BY oda.actual_delivery_time DESC, oda.created_at DESC
            LIMIT ? OFFSET ?
        ]]
        return db.query(query, delivery_partner_id, limit, offset)
    elseif status then
        -- Specific status filter
        query = [[
            SELECT oda.*, o.order_number, o.total_amount, o.customer_id, o.status as order_status,
                   o.shipping_address, o.delivery_latitude, o.delivery_longitude,
                   s.name as store_name, s.slug as store_slug, s.contact_phone as store_phone
            FROM order_delivery_assignments oda
            INNER JOIN orders o ON oda.order_id = o.id
            INNER JOIN stores s ON o.store_id = s.id
            WHERE oda.delivery_partner_id = ?
            AND oda.status = ?
            ORDER BY oda.created_at DESC
            LIMIT ? OFFSET ?
        ]]
        return db.query(query, delivery_partner_id, status, limit, offset)
    else
        -- No status filter, return all
        query = [[
            SELECT oda.*, o.order_number, o.total_amount, o.customer_id, o.status as order_status,
                   o.shipping_address, o.delivery_latitude, o.delivery_longitude,
                   s.name as store_name, s.slug as store_slug, s.contact_phone as store_phone
            FROM order_delivery_assignments oda
            INNER JOIN orders o ON oda.order_id = o.id
            INNER JOIN stores s ON o.store_id = s.id
            WHERE oda.delivery_partner_id = ?
            ORDER BY oda.created_at DESC
            LIMIT ? OFFSET ?
        ]]
        return db.query(query, delivery_partner_id, limit, offset)
    end
end

-- Update assignment status
function OrderDeliveryAssignmentQueries.updateStatus(id, status, additional_data)
    local update_data = {
        status = status,
        updated_at = db.format_date()
    }

    if status == 'picked_up' then
        update_data.actual_pickup_time = additional_data and additional_data.actual_pickup_time or db.format_date()
    elseif status == 'delivered' then
        update_data.actual_delivery_time = additional_data and additional_data.actual_delivery_time or db.format_date()
        if additional_data and additional_data.proof_of_delivery then
            update_data.proof_of_delivery = additional_data.proof_of_delivery
        end
    end

    db.update("order_delivery_assignments", update_data, "id = ?", id)

    local result = db.select("* FROM order_delivery_assignments WHERE id = ?", id)
    return result and result[1] or nil
end

-- Update assignment
function OrderDeliveryAssignmentQueries.update(id, params)
    params.updated_at = db.format_date()
    db.update("order_delivery_assignments", params, "id = ?", id)

    local result = db.select("* FROM order_delivery_assignments WHERE id = ?", id)
    return result and result[1] or nil
end

-- Get delivery statistics for partner
function OrderDeliveryAssignmentQueries.getPartnerStats(delivery_partner_id, from_date, to_date)
    local query = [[
        SELECT
            COUNT(*) as total_assignments,
            COUNT(CASE WHEN status = 'delivered' THEN 1 END) as completed,
            COUNT(CASE WHEN status = 'failed' THEN 1 END) as failed,
            COUNT(CASE WHEN status = 'in_transit' THEN 1 END) as in_transit,
            SUM(delivery_fee) as total_earnings,
            AVG(distance_km) as avg_distance
        FROM order_delivery_assignments
        WHERE delivery_partner_id = ?
    ]]

    local params = {delivery_partner_id}

    if from_date then
        query = query .. " AND created_at >= ?"
        table.insert(params, from_date)
    end

    if to_date then
        query = query .. " AND created_at <= ?"
        table.insert(params, to_date)
    end

    local result = db.query(query, unpack(params))
    return result and result[1] or nil
end

-- Get active assignments count for partner
function OrderDeliveryAssignmentQueries.getActiveCount(delivery_partner_id)
    local query = [[
        SELECT COUNT(*) as count
        FROM order_delivery_assignments
        WHERE delivery_partner_id = ?
        AND status IN ('accepted', 'picked_up', 'in_transit')
    ]]

    local result = db.query(query, delivery_partner_id)
    return result and result[1] and result[1].count or 0
end

-- Get assignment with full details by UUID
function OrderDeliveryAssignmentQueries.getWithDetails(assignment_uuid)
    local query = [[
        SELECT oda.*,
               o.id as order_id_fk,
               o.uuid as order_uuid,
               o.order_number,
               o.total_amount,
               o.subtotal,
               o.status as order_status,
               o.billing_address,
               o.shipping_address,
               o.customer_notes,
               o.delivery_latitude,
               o.delivery_longitude,
               s.id as store_id,
               s.uuid as store_uuid,
               s.name as store_name,
               s.slug as store_slug,
               s.contact_phone as store_phone,
               s.user_id as store_owner_id,
               dp.id as delivery_partner_id_fk,
               dp.uuid as delivery_partner_uuid,
               dp.company_name as delivery_company,
               dp.contact_person_name,
               dp.contact_person_phone,
               dp.user_id as delivery_partner_user_id,
               dp.vehicle_types,
               dp.rating as partner_rating,
               dp.total_deliveries as partner_total_deliveries,
               c.id as customer_id,
               c.email as customer_email,
               c.phone as customer_phone,
               c.first_name as customer_first_name,
               c.last_name as customer_last_name
        FROM order_delivery_assignments oda
        INNER JOIN orders o ON oda.order_id = o.id
        INNER JOIN stores s ON o.store_id = s.id
        INNER JOIN delivery_partners dp ON oda.delivery_partner_id = dp.id
        LEFT JOIN customers c ON o.customer_id = c.id
        WHERE oda.uuid = ?
    ]]

    local result = db.query(query, assignment_uuid)
    if not result or #result == 0 then
        return nil
    end

    local assignment = result[1]

    -- Parse JSON fields
    if assignment.shipping_address and assignment.shipping_address ~= "" then
        local ok, parsed = pcall(function()
            return require("cjson").decode(assignment.shipping_address)
        end)
        if ok and parsed then
            assignment.delivery_address = parsed.address1 or ""
            assignment.delivery_city = parsed.city or ""
            assignment.delivery_state = parsed.state or ""
            assignment.delivery_postal_code = parsed.zip or ""
            assignment.customer_name = parsed.name or ""
        end
    end

    if assignment.billing_address and assignment.billing_address ~= "" then
        local ok, parsed = pcall(function()
            return require("cjson").decode(assignment.billing_address)
        end)
        if ok and parsed then
            assignment.billing_address_parsed = parsed
        end
    end

    -- Parse vehicle types
    if assignment.vehicle_types and assignment.vehicle_types ~= "" then
        local ok, parsed = pcall(function()
            return require("cjson").decode(assignment.vehicle_types)
        end)
        if ok and type(parsed) == "table" then
            assignment.vehicle_types_array = parsed
        end
    end

    return assignment
end

-- Get assignment statistics for partner
function OrderDeliveryAssignmentQueries.getStatistics(delivery_partner_id)
    local query = [[
        SELECT
            COUNT(*) as total_assignments,
            COUNT(CASE WHEN status = 'delivered' THEN 1 END) as completed_deliveries,
            COUNT(CASE WHEN status = 'failed' THEN 1 END) as failed_deliveries,
            COUNT(CASE WHEN status = 'in_transit' THEN 1 END) as in_transit_deliveries,
            SUM(CASE WHEN status = 'delivered' THEN delivery_fee ELSE 0 END) as total_earnings,
            AVG(CASE WHEN status = 'delivered' THEN delivery_fee END) as average_fee,
            MIN(CASE WHEN status = 'delivered' THEN delivery_fee END) as min_fee,
            MAX(CASE WHEN status = 'delivered' THEN delivery_fee END) as max_fee
        FROM order_delivery_assignments
        WHERE delivery_partner_id = ?
    ]]

    local result = db.query(query, delivery_partner_id)
    return result and result[1] or {}
end

-- Alias methods for compatibility with routes
function OrderDeliveryAssignmentQueries.getByDeliveryPartner(delivery_partner_id, status)
    local assignments = OrderDeliveryAssignmentQueries.findByPartnerId(delivery_partner_id, status)

    -- Transform to include parsed shipping address
    for _, assignment in ipairs(assignments) do
        if assignment.shipping_address and assignment.shipping_address ~= "" then
            local ok, parsed = pcall(function()
                return require("cjson").decode(assignment.shipping_address)
            end)
            if ok and parsed then
                assignment.delivery_address = parsed.address1 or ""
                assignment.delivery_city = parsed.city or ""
                assignment.delivery_state = parsed.state or ""
                assignment.delivery_postal_code = parsed.zip or ""
                assignment.customer_name = parsed.name or ""
            end
        end
    end

    return assignments
end

return OrderDeliveryAssignmentQueries
