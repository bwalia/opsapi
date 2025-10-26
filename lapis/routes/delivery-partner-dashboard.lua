local lapis = require("lapis")
local respond_to = require("lapis.application").respond_to
local AuthMiddleware = require("middleware.auth")
local DeliveryPartnerQueries = require("queries.DeliveryPartnerQueries")
local DeliveryPartnerAreaQueries = require("queries.DeliveryPartnerAreaQueries")
local cjson = require("cjson")
local db = require("lapis.db")

return function(app)
    -- Helper function to parse JSON body
    local function parse_json_body()
        local ok, result = pcall(function()
            ngx.req.read_body()
            local body = ngx.req.get_body_data()
            if not body or body == "" then
                return {}
            end
            return cjson.decode(body)
        end)

        if ok and type(result) == "table" then
            return result
        end
        return {}
    end
    -- Get dashboard statistics for delivery partner
    app:match("/api/v2/delivery-partner/dashboard", respond_to({
        GET = AuthMiddleware.requireAuth(function(self)
            -- Get user ID from current_user
            local user = db.query("SELECT id FROM users WHERE uuid = ?", self.current_user.uuid)[1]
            if not user then
                return { status = 404, json = { error = "User not found" } }
            end
            local user_id = user.id

            -- Get delivery partner profile
            local delivery_partner = db.query("SELECT * FROM delivery_partners WHERE user_id = ?", user_id)[1]
            if not delivery_partner then
                return { status = 404, json = { error = "Delivery partner profile not found" } }
            end

            -- Get comprehensive statistics
            local success, stats = pcall(function()
                return DeliveryPartnerQueries.getStatistics(delivery_partner.id)
            end)

            if not success then
                ngx.log(ngx.ERR, "Failed to get statistics: " .. tostring(stats))
                return { status = 500, json = { error = "Failed to fetch statistics" } }
            end

            -- Get today's earnings
            local today_start = os.date("%Y-%m-%d 00:00:00")
            local todays_earnings = db.query([[
                SELECT COALESCE(SUM(delivery_fee), 0) as total
                FROM order_delivery_assignments
                WHERE delivery_partner_id = ?
                AND status = 'delivered'
                AND DATE(actual_delivery_time) = DATE(?)
            ]], delivery_partner.id, today_start)[1].total or 0

            -- Calculate success rate
            local success_rate = 0
            if stats.total_deliveries > 0 then
                success_rate = (stats.successful_deliveries / stats.total_deliveries) * 100
            end

            return { json = {
                active_deliveries = delivery_partner.current_active_orders or 0,
                todays_earnings = tonumber(todays_earnings) or 0,
                success_rate = success_rate,
                average_rating = tonumber(delivery_partner.rating) or 0,
                current_capacity = delivery_partner.current_active_orders or 0,
                max_capacity = delivery_partner.max_daily_capacity or 0,
                total_deliveries = stats.total_deliveries or 0,
                successful_deliveries = stats.successful_deliveries or 0,
                total_earnings = tonumber(stats.total_earnings) or 0,
                is_verified = delivery_partner.is_verified,
                is_active = delivery_partner.is_active
            }}
        end)
    }))

    -- Get available orders in delivery partner's service area
    app:match("/api/v2/delivery-partner/available-orders", respond_to({
        GET = AuthMiddleware.requireAuth(function(self)
            -- Get user ID from current_user
            local user = db.query("SELECT id FROM users WHERE uuid = ?", self.current_user.uuid)[1]
            if not user then
                return { status = 404, json = { error = "User not found" } }
            end
            local user_id = user.id

            -- Get delivery partner profile
            local delivery_partner = db.query("SELECT * FROM delivery_partners WHERE user_id = ?", user_id)[1]
            if not delivery_partner then
                return { status = 404, json = { error = "Delivery partner profile not found" } }
            end

            -- Check if partner is verified and active
            if not delivery_partner.is_verified or not delivery_partner.is_active then
                return { json = { orders = {}, message = "Your account needs to be verified and active to see available orders" } }
            end

            -- Check if partner has capacity
            if delivery_partner.current_active_orders >= delivery_partner.max_daily_capacity then
                return { json = { orders = {}, message = "You have reached maximum capacity for today" } }
            end

            -- Check if partner has location set up for geolocation-based matching
            if not delivery_partner.latitude or not delivery_partner.longitude then
                -- Fallback to area-based matching if geolocation not set up
                ngx.log(ngx.WARN, string.format(
                    "[AREA-BASED] Delivery partner ID=%d has no geolocation data (lat=%s, lng=%s), using area-based matching",
                    delivery_partner.id,
                    tostring(delivery_partner.latitude),
                    tostring(delivery_partner.longitude)
                ))

                local areas = db.query([[
                    SELECT DISTINCT city, state, country
                    FROM delivery_partner_areas
                    WHERE delivery_partner_id = ? AND is_active = true
                ]], delivery_partner.id)

                if not areas or #areas == 0 then
                    ngx.log(ngx.WARN, "[AREA-BASED] No service areas configured for delivery partner ID=" .. delivery_partner.id)
                    return { json = {
                        orders = {},
                        message = "Please set up your service location or add service areas to your profile",
                        matching_mode = "area_based",
                        total_matches = 0
                    } }
                end

                ngx.log(ngx.INFO, string.format("[AREA-BASED] Found %d service areas configured", #areas))

                -- Build query to find orders in service areas (case-insensitive city matching)
                local area_conditions = {}
                for i, area in ipairs(areas) do
                    ngx.log(ngx.INFO, string.format(
                        "[AREA-BASED] Service area #%d: city='%s', state='%s', country='%s'",
                        i, area.city or "N/A", area.state or "N/A", area.country or "N/A"
                    ))
                    table.insert(area_conditions, string.format(
                        "(LOWER(shipping_address::json->>'city') = LOWER(%s))",
                        db.escape_literal(area.city)
                    ))
                end

                local query = string.format([[
                    SELECT
                        o.id,
                        o.uuid,
                        o.order_number,
                        o.total_amount,
                        o.status,
                        o.shipping_address,
                        o.billing_address,
                        o.delivery_latitude,
                        o.delivery_longitude,
                        shipping_address::json->>'city' as delivery_city,
                        shipping_address::json->>'state' as delivery_state,
                        shipping_address::json->>'zip' as delivery_postal_code,
                        shipping_address::json->>'address1' as delivery_address,
                        shipping_address::json->>'name' as customer_name,
                        o.created_at,
                        s.name as store_name,
                        s.slug as store_slug,
                        s.contact_phone as store_phone,
                        NULL::numeric as distance_km
                    FROM orders o
                    INNER JOIN stores s ON o.store_id = s.id
                    LEFT JOIN order_delivery_assignments oda ON o.id = oda.order_id
                    LEFT JOIN delivery_requests dr ON o.id = dr.order_id
                        AND dr.delivery_partner_id = %d
                        AND dr.status = 'pending'
                    WHERE o.status IN ('pending', 'confirmed', 'accepted', 'preparing', 'packing', 'processing')
                    AND oda.id IS NULL
                    AND dr.id IS NULL
                    AND o.shipping_address IS NOT NULL
                    AND o.shipping_address != '{}'
                    AND (%s)
                    ORDER BY o.created_at DESC
                    LIMIT 50
                ]], delivery_partner.id, table.concat(area_conditions, " OR "))

                ngx.log(ngx.INFO, "[AREA-BASED] Executing query: " .. query)

                local success, orders = pcall(function()
                    return db.query(query)
                end)

                if not success then
                    ngx.log(ngx.ERR, "[AREA-BASED ERROR] Failed to execute area query: " .. tostring(orders))
                    return {
                        status = 500,
                        json = {
                            error = "Failed to find orders in service areas",
                            details = tostring(orders)
                        }
                    }
                end

                ngx.log(ngx.INFO, string.format("[AREA-BASED] Found %d orders in service areas", orders and #orders or 0))

                -- Log each matched order
                if orders and #orders > 0 then
                    for i, order in ipairs(orders) do
                        ngx.log(ngx.INFO, string.format(
                            "[AREA-BASED] Match #%d: Order %s (ID=%d) - City: %s, State: %s",
                            i, order.order_number or "N/A", order.id, order.delivery_city or "N/A", order.delivery_state or "N/A"
                        ))
                    end
                else
                    ngx.log(ngx.WARN, "[AREA-BASED] No orders matched the configured service areas")
                end

                return { json = {
                    orders = orders or {},
                    matching_mode = "area_based",
                    total_matches = orders and #orders or 0,
                    service_areas = areas
                } }
            end

            -- Use geolocation-based matching with Haversine formula (works without PostGIS)
            local service_radius = delivery_partner.service_radius_km or 10

            ngx.log(ngx.INFO, string.format(
                "[GEOLOCATION] Finding orders within %f km radius for delivery partner ID=%d at location: lat=%f, lng=%f",
                service_radius, delivery_partner.id, delivery_partner.latitude, delivery_partner.longitude
            ))

            -- Haversine formula to calculate great-circle distance between two points
            -- Formula: distance = R * 2 * asin(sqrt(sin²(Δlat/2) + cos(lat1) * cos(lat2) * sin²(Δlon/2)))
            -- Where R = Earth's radius in km (6371)
            local query = [[
                SELECT * FROM (
                    SELECT
                        o.id,
                        o.uuid,
                        o.order_number,
                        o.total_amount,
                        o.status,
                        o.shipping_address,
                        o.billing_address,
                        o.delivery_latitude,
                        o.delivery_longitude,
                        shipping_address::json->>'city' as delivery_city,
                        shipping_address::json->>'state' as delivery_state,
                        shipping_address::json->>'zip' as delivery_postal_code,
                        shipping_address::json->>'address1' as delivery_address,
                        shipping_address::json->>'name' as customer_name,
                        o.created_at,
                        s.name as store_name,
                        s.slug as store_slug,
                        s.contact_phone as store_phone,
                        ROUND(
                            CAST(
                                6371 * 2 * ASIN(
                                    SQRT(
                                        POWER(SIN(RADIANS(o.delivery_latitude - ?::numeric) / 2), 2) +
                                        COS(RADIANS(?::numeric)) * COS(RADIANS(o.delivery_latitude)) *
                                        POWER(SIN(RADIANS(o.delivery_longitude - ?::numeric) / 2), 2)
                                    )
                                ) AS numeric
                            ), 2
                        ) as distance_km
                    FROM orders o
                    INNER JOIN stores s ON o.store_id = s.id
                    LEFT JOIN order_delivery_assignments oda ON o.id = oda.order_id
                    LEFT JOIN delivery_requests dr ON o.id = dr.order_id
                        AND dr.delivery_partner_id = ?
                        AND dr.status = 'pending'
                    WHERE o.status IN ('pending', 'confirmed', 'accepted', 'preparing', 'packing', 'processing')
                    AND oda.id IS NULL
                    AND dr.id IS NULL
                    AND o.delivery_latitude IS NOT NULL
                    AND o.delivery_longitude IS NOT NULL
                ) subquery
                WHERE distance_km <= ?
                ORDER BY distance_km ASC, created_at DESC
                LIMIT 50
            ]]

            local success, orders = pcall(function()
                return db.query(query,
                    delivery_partner.latitude,  -- For lat difference calculation
                    delivery_partner.latitude,  -- For COS calculation
                    delivery_partner.longitude, -- For lng difference calculation
                    delivery_partner.id,        -- For delivery_requests check
                    service_radius              -- Maximum distance in km
                )
            end)

            if not success then
                ngx.log(ngx.ERR, "[GEOLOCATION ERROR] Failed to execute distance query: " .. tostring(orders))
                return {
                    status = 500,
                    json = {
                        error = "Failed to find nearby orders",
                        details = tostring(orders)
                    }
                }
            end

            ngx.log(ngx.INFO, string.format(
                "[GEOLOCATION] Found %d orders within %f km radius",
                orders and #orders or 0,
                service_radius
            ))

            -- Log each matched order with distance details
            if orders and #orders > 0 then
                for i, order in ipairs(orders) do
                    ngx.log(ngx.INFO, string.format(
                        "[GEOLOCATION] Match #%d: Order %s (ID=%d) - Distance: %f km - City: %s",
                        i, order.order_number or "N/A", order.id, order.distance_km or 0, order.delivery_city or "N/A"
                    ))
                end
            else
                ngx.log(ngx.WARN, "[GEOLOCATION] No orders found within service radius. Check if there are orders with geolocation data in the system.")
            end

            return { json = {
                orders = orders or {},
                partner_location = {
                    latitude = delivery_partner.latitude,
                    longitude = delivery_partner.longitude,
                    service_radius_km = service_radius
                },
                matching_mode = "geolocation_based",
                total_matches = orders and #orders or 0
            } }
        end)
    }))

    -- Get earnings report for delivery partner
    app:match("/api/v2/delivery-partner/earnings", respond_to({
        GET = AuthMiddleware.requireAuth(function(self)
            -- Get user ID from current_user
            local user = db.query("SELECT id FROM users WHERE uuid = ?", self.current_user.uuid)[1]
            if not user then
                return { status = 404, json = { error = "User not found" } }
            end
            local user_id = user.id
            local period = self.params.period or "all"  -- all, today, week, month

            -- Get delivery partner profile
            local delivery_partner = db.query("SELECT * FROM delivery_partners WHERE user_id = ?", user_id)[1]
            if not delivery_partner then
                return { status = 404, json = { error = "Delivery partner profile not found" } }
            end

            local date_filter = ""
            if period == "today" then
                date_filter = "AND DATE(actual_delivery_time) = DATE(NOW())"
            elseif period == "week" then
                date_filter = "AND actual_delivery_time >= NOW() - INTERVAL '7 days'"
            elseif period == "month" then
                date_filter = "AND actual_delivery_time >= NOW() - INTERVAL '30 days'"
            end

            local earnings = db.query(string.format([[
                SELECT
                    COUNT(*) as total_deliveries,
                    COALESCE(SUM(delivery_fee), 0) as total_earnings,
                    COALESCE(AVG(delivery_fee), 0) as average_fee,
                    COALESCE(MIN(delivery_fee), 0) as min_fee,
                    COALESCE(MAX(delivery_fee), 0) as max_fee
                FROM order_delivery_assignments
                WHERE delivery_partner_id = ?
                AND status = 'delivered'
                %s
            ]], date_filter), delivery_partner.id)[1]

            -- Get detailed delivery list
            local deliveries = db.query(string.format([[
                SELECT
                    oda.uuid,
                    oda.tracking_number,
                    oda.delivery_fee,
                    oda.actual_pickup_time,
                    oda.actual_delivery_time,
                    oda.distance_km,
                    o.order_number,
                    o.total_amount as order_amount,
                    s.name as store_name
                FROM order_delivery_assignments oda
                INNER JOIN orders o ON oda.order_id = o.id
                INNER JOIN stores s ON o.store_id = s.id
                WHERE oda.delivery_partner_id = ?
                AND oda.status = 'delivered'
                %s
                ORDER BY oda.actual_delivery_time DESC
                LIMIT 100
            ]], date_filter), delivery_partner.id)

            return { json = {
                summary = {
                    total_deliveries = earnings.total_deliveries or 0,
                    total_earnings = tonumber(earnings.total_earnings) or 0,
                    average_fee = tonumber(earnings.average_fee) or 0,
                    min_fee = tonumber(earnings.min_fee) or 0,
                    max_fee = tonumber(earnings.max_fee) or 0,
                    period = period
                },
                deliveries = deliveries or {}
            }}
        end)
    }))

    -- Request to deliver an available order
    app:match("/api/v2/delivery-partner/request-order", respond_to({
        POST = AuthMiddleware.requireAuth(function(self)
            -- Get user ID from current_user
            local user = db.query("SELECT id FROM users WHERE uuid = ?", self.current_user.uuid)[1]
            if not user then
                return { status = 404, json = { error = "User not found" } }
            end
            local user_id = user.id

            -- Parse JSON body
            local params = parse_json_body()
            -- Fallback to form params if JSON body is empty
            if not params or not params.order_id then
                params = self.params
            end

            if not params.order_id then
                return { status = 400, json = { error = "order_id is required" } }
            end

            -- Get delivery partner profile
            local delivery_partner = db.query("SELECT * FROM delivery_partners WHERE user_id = ?", user_id)[1]
            if not delivery_partner then
                return { status = 404, json = { error = "Delivery partner profile not found" } }
            end

            -- Check if verified and active
            if not delivery_partner.is_verified then
                return { status = 403, json = { error = "Your account needs to be verified first" } }
            end

            if not delivery_partner.is_active then
                return { status = 403, json = { error = "Your account is not active" } }
            end

            -- Check capacity
            if delivery_partner.current_active_orders >= delivery_partner.max_daily_capacity then
                return { status = 400, json = { error = "You are at full capacity" } }
            end

            -- Get order
            local order = db.query("SELECT * FROM orders WHERE id = ?", params.order_id)[1]
            if not order then
                return { status = 404, json = { error = "Order not found" } }
            end

            -- Check if order already has assignment
            local existing_assignment = db.query("SELECT * FROM order_delivery_assignments WHERE order_id = ?", params.order_id)[1]
            if existing_assignment then
                return { status = 400, json = { error = "Order already has a delivery assignment" } }
            end

            -- Check if request already exists
            local existing_request = db.query([[
                SELECT * FROM delivery_requests
                WHERE order_id = ? AND delivery_partner_id = ? AND status = 'pending'
            ]], params.order_id, delivery_partner.id)[1]

            if existing_request then
                return { status = 400, json = { error = "You already have a pending request for this order" } }
            end

            -- Calculate proposed fee based on pricing model
            local proposed_fee = 0
            if delivery_partner.pricing_model == "flat" then
                proposed_fee = delivery_partner.base_charge or 0
            elseif delivery_partner.pricing_model == "per_km" then
                local distance = params.distance_km or 0
                proposed_fee = (delivery_partner.per_km_charge or 0) * distance
            elseif delivery_partner.pricing_model == "percentage" then
                proposed_fee = (tonumber(order.total_amount) or 0) * ((delivery_partner.percentage_charge or 0) / 100)
            elseif delivery_partner.pricing_model == "hybrid" then
                local distance = params.distance_km or 0
                local distance_fee = (delivery_partner.per_km_charge or 0) * distance
                local percentage_fee = (tonumber(order.total_amount) or 0) * ((delivery_partner.percentage_charge or 0) / 100)
                proposed_fee = (delivery_partner.base_charge or 0) + distance_fee + percentage_fee
            end

            -- Allow override if provided
            if params.proposed_fee then
                proposed_fee = params.proposed_fee
            end

            -- Create delivery request
            local success, result = pcall(function()
                local request_id = db.insert("delivery_requests", {
                    uuid = db.raw("gen_random_uuid()"),
                    order_id = params.order_id,
                    delivery_partner_id = delivery_partner.id,
                    request_type = "partner_to_seller",
                    status = "pending",
                    proposed_fee = proposed_fee,
                    message = params.message or "",
                    expires_at = db.raw("NOW() + INTERVAL '24 hours'"),
                    created_at = db.raw("NOW()"),
                    updated_at = db.raw("NOW()")
                }, "id")

                -- The insert returns the ID value directly when specifying return column
                local request_id_value = type(request_id) == "table" and request_id.id or request_id

                -- Fetch the created request
                local created_request = db.query("SELECT * FROM delivery_requests WHERE id = ?", request_id_value)[1]

                if not created_request then
                    error("Failed to retrieve created delivery request")
                end

                ngx.log(ngx.INFO, string.format("Delivery request created: ID=%d for order=%d by partner=%d",
                    request_id_value, params.order_id, delivery_partner.id))

                return created_request
            end)

            if not success then
                ngx.log(ngx.ERR, "Error creating delivery request: " .. tostring(result))
                return { status = 500, json = { error = "Failed to create delivery request: " .. tostring(result) } }
            end

            return { json = {
                success = true,
                message = "Delivery request created successfully",
                request = result
            }}
        end)
    }))
end
