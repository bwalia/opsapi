local DeliveryPartnerModel = require("models.DeliveryPartnerModel")
local db = require("lapis.db")
local Global = require("helper.global")

local DeliveryPartnerQueries = {}

-- Create delivery partner profile
function DeliveryPartnerQueries.create(params)
    local uuid = Global.generateUUID()

    local delivery_partner = DeliveryPartnerModel:create({
        uuid = uuid,
        user_id = params.user_id,
        company_name = params.company_name,
        company_registration_number = params.company_registration_number,
        contact_person_name = params.contact_person_name,
        contact_person_phone = params.contact_person_phone,
        contact_person_email = params.contact_person_email,
        business_address = params.business_address,
        service_type = params.service_type or 'standard',
        vehicle_types = params.vehicle_types or '[]',
        max_daily_capacity = params.max_daily_capacity or 10,
        service_radius_km = params.service_radius_km or 10,
        base_charge = params.base_charge or 0,
        per_km_charge = params.per_km_charge or 0,
        percentage_charge = params.percentage_charge or 0,
        pricing_model = params.pricing_model or 'flat',
        bank_account_number = params.bank_account_number,
        bank_name = params.bank_name,
        bank_ifsc_code = params.bank_ifsc_code,
        created_at = db.format_date(),
        updated_at = db.format_date()
    })

    return delivery_partner
end

-- Get delivery partner by user_id
function DeliveryPartnerQueries.findByUserId(user_id)
    return DeliveryPartnerModel:find({ user_id = user_id })
end

-- Get delivery partner by uuid
function DeliveryPartnerQueries.findByUuid(uuid)
    return DeliveryPartnerModel:find({ uuid = uuid })
end

-- Get delivery partner by id
function DeliveryPartnerQueries.findById(id)
    return DeliveryPartnerModel:find({ id = id })
end

-- Update delivery partner
function DeliveryPartnerQueries.update(id, params)
    local delivery_partner = DeliveryPartnerModel:find({ id = id })
    if not delivery_partner then
        return nil, "Delivery partner not found"
    end

    delivery_partner:update(params)
    return delivery_partner
end

-- Get delivery partners by area (city, state)
function DeliveryPartnerQueries.findByArea(city, state, country)
    country = country or 'India'

    local query = [[
        SELECT DISTINCT dp.*
        FROM delivery_partners dp
        INNER JOIN delivery_partner_areas dpa ON dp.id = dpa.delivery_partner_id
        WHERE dpa.city = ?
        AND dpa.state = ?
        AND dpa.country = ?
        AND dp.is_active = true
        AND dp.is_verified = true
        AND dpa.is_active = true
        ORDER BY dp.rating DESC, dp.total_deliveries DESC
    ]]

    return db.query(query, city, state, country)
end

-- Get available delivery partners (not at capacity)
function DeliveryPartnerQueries.findAvailable(city, state, country)
    country = country or 'India'

    local query = [[
        SELECT DISTINCT dp.*
        FROM delivery_partners dp
        INNER JOIN delivery_partner_areas dpa ON dp.id = dpa.delivery_partner_id
        WHERE dpa.city = ?
        AND dpa.state = ?
        AND dpa.country = ?
        AND dp.is_active = true
        AND dp.is_verified = true
        AND dpa.is_active = true
        AND dp.current_active_orders < dp.max_daily_capacity
        ORDER BY dp.rating DESC, dp.current_active_orders ASC
    ]]

    return db.query(query, city, state, country)
end

-- Get delivery partners for a store
function DeliveryPartnerQueries.findByStoreId(store_id)
    local query = [[
        SELECT dp.*, sdp.is_preferred
        FROM delivery_partners dp
        INNER JOIN store_delivery_partners sdp ON dp.id = sdp.delivery_partner_id
        WHERE sdp.store_id = ?
        AND sdp.is_active = true
        AND dp.is_active = true
        ORDER BY sdp.is_preferred DESC, dp.rating DESC
    ]]

    return db.query(query, store_id)
end

-- Get delivery partner statistics
function DeliveryPartnerQueries.getStatistics(delivery_partner_id)
    local query = [[
        SELECT
            dp.total_deliveries,
            dp.successful_deliveries,
            dp.rating,
            dp.current_active_orders,
            dp.max_daily_capacity,
            COUNT(DISTINCT oda.id) as total_assignments,
            COUNT(DISTINCT CASE WHEN oda.status = 'delivered' THEN oda.id END) as completed_deliveries,
            COUNT(DISTINCT CASE WHEN oda.status = 'in_transit' THEN oda.id END) as in_transit_deliveries,
            COUNT(DISTINCT CASE WHEN oda.status = 'failed' THEN oda.id END) as failed_deliveries,
            AVG(CASE WHEN dpr.rating IS NOT NULL THEN dpr.rating END) as average_review_rating,
            COUNT(DISTINCT dpr.id) as total_reviews
        FROM delivery_partners dp
        LEFT JOIN order_delivery_assignments oda ON dp.id = oda.delivery_partner_id
        LEFT JOIN delivery_partner_reviews dpr ON dp.id = dpr.delivery_partner_id
        WHERE dp.id = ?
        GROUP BY dp.id, dp.total_deliveries, dp.successful_deliveries, dp.rating, dp.current_active_orders, dp.max_daily_capacity
    ]]

    local result = db.query(query, delivery_partner_id)
    return result and result[1] or nil
end

-- Search delivery partners
function DeliveryPartnerQueries.search(params)
    local conditions = {"dp.is_active = true"}
    local query_params = {}

    if params.city then
        table.insert(conditions, "dpa.city = ?")
        table.insert(query_params, params.city)
    end

    if params.state then
        table.insert(conditions, "dpa.state = ?")
        table.insert(query_params, params.state)
    end

    if params.is_verified ~= nil then
        table.insert(conditions, "dp.is_verified = ?")
        table.insert(query_params, params.is_verified)
    end

    if params.service_type then
        table.insert(conditions, "dp.service_type = ?")
        table.insert(query_params, params.service_type)
    end

    if params.min_rating then
        table.insert(conditions, "dp.rating >= ?")
        table.insert(query_params, params.min_rating)
    end

    local where_clause = table.concat(conditions, " AND ")

    local query = [[
        SELECT DISTINCT dp.*
        FROM delivery_partners dp
        LEFT JOIN delivery_partner_areas dpa ON dp.id = dpa.delivery_partner_id
        WHERE ]] .. where_clause .. [[
        ORDER BY dp.rating DESC, dp.total_deliveries DESC
        LIMIT ?
        OFFSET ?
    ]]

    table.insert(query_params, params.limit or 20)
    table.insert(query_params, params.offset or 0)

    return db.query(query, unpack(query_params))
end

-- Increment active orders count
function DeliveryPartnerQueries.incrementActiveOrders(delivery_partner_id)
    db.query("UPDATE delivery_partners SET current_active_orders = current_active_orders + 1 WHERE id = ?", delivery_partner_id)
end

-- Decrement active orders count
function DeliveryPartnerQueries.decrementActiveOrders(delivery_partner_id)
    db.query("UPDATE delivery_partners SET current_active_orders = GREATEST(0, current_active_orders - 1) WHERE id = ?", delivery_partner_id)
end

-- Update rating and delivery counts
function DeliveryPartnerQueries.updateDeliveryStats(delivery_partner_id, successful)
    local update_query
    if successful then
        update_query = [[
            UPDATE delivery_partners
            SET total_deliveries = total_deliveries + 1,
                successful_deliveries = successful_deliveries + 1,
                updated_at = ?
            WHERE id = ?
        ]]
    else
        update_query = [[
            UPDATE delivery_partners
            SET total_deliveries = total_deliveries + 1,
                updated_at = ?
            WHERE id = ?
        ]]
    end

    db.query(update_query, db.format_date(), delivery_partner_id)
end

-- Calculate average rating
function DeliveryPartnerQueries.recalculateRating(delivery_partner_id)
    local query = [[
        UPDATE delivery_partners
        SET rating = COALESCE((
            SELECT AVG(rating)::numeric(3,2)
            FROM delivery_partner_reviews
            WHERE delivery_partner_id = ?
        ), 0)
        WHERE id = ?
    ]]

    db.query(query, delivery_partner_id, delivery_partner_id)
end

return DeliveryPartnerQueries
