--[[
    Enhanced Delivery Partner Dashboard with Geolocation

    Professional dashboard with:
    - Real-time nearby order display
    - Distance calculations
    - Geofenced order matching
    - Notification management
    - Live statistics

    Author: Senior Backend Engineer
    Date: 2025-01-19
]]--

local respond_to = require("lapis.application").respond_to
local AuthMiddleware = require("middleware.auth")
local db = require("lapis.db")
local cjson = require("cjson")
local DeliveryNotificationService = require("lib.delivery-notification-service")

return function(app)
    --[[
        Enhanced Dashboard Statistics with Geolocation Insights
    ]]--
    app:match("delivery_partner_dashboard_geo", "/api/v2/delivery-partner/dashboard", respond_to({
        GET = AuthMiddleware.requireAuth(function(self)
            local user = db.query("SELECT id FROM users WHERE uuid = ?", self.current_user.uuid)[1]
            if not user then
                return { status = 404, json = { error = "User not found" } }
            end

            local delivery_partner = db.query("SELECT * FROM delivery_partners WHERE user_id = ?", user.id)[1]
            if not delivery_partner then
                return { status = 404, json = { error = "Delivery partner profile not found" } }
            end

            -- Get comprehensive statistics
            local stats = db.query([[
                SELECT
                    dp.current_active_orders,
                    dp.max_daily_capacity,
                    dp.total_deliveries,
                    dp.successful_deliveries,
                    dp.rating,
                    dp.is_verified,
                    dp.is_active,
                    dp.latitude,
                    dp.longitude,
                    dp.service_radius_km,
                    dp.city,
                    dp.state,
                    COALESCE(SUM(oda.delivery_fee) FILTER (
                        WHERE oda.status = 'delivered'
                        AND DATE(oda.actual_delivery_time) = CURRENT_DATE
                    ), 0) as todays_earnings,
                    COALESCE(SUM(oda.delivery_fee) FILTER (
                        WHERE oda.status = 'delivered'
                    ), 0) as total_earnings,
                    COUNT(DISTINCT oda.id) FILTER (
                        WHERE oda.status IN ('pending', 'accepted', 'picked_up', 'in_transit')
                    ) as active_deliveries,
                    COUNT(DISTINCT n.id) FILTER (
                        WHERE n.is_read = FALSE
                        AND (n.expires_at IS NULL OR n.expires_at > NOW())
                    ) as unread_notifications
                FROM delivery_partners dp
                LEFT JOIN order_delivery_assignments oda ON dp.id = oda.delivery_partner_id
                LEFT JOIN delivery_partner_notifications n ON dp.id = n.delivery_partner_id
                WHERE dp.id = ?
                GROUP BY dp.id
            ]], delivery_partner.id)[1]

            -- Calculate success rate
            local success_rate = 0
            if stats.total_deliveries > 0 then
                success_rate = (stats.successful_deliveries / stats.total_deliveries) * 100
            end

            -- Calculate capacity percentage
            local capacity_percentage = 0
            if stats.max_daily_capacity > 0 then
                capacity_percentage = (stats.current_active_orders / stats.max_daily_capacity) * 100
            end

            return {
                json = {
                    -- Location info
                    location = {
                        latitude = tonumber(stats.latitude),
                        longitude = tonumber(stats.longitude),
                        service_radius_km = tonumber(stats.service_radius_km),
                        city = stats.city,
                        state = stats.state
                    },

                    -- Performance metrics
                    metrics = {
                        active_deliveries = tonumber(stats.active_deliveries) or 0,
                        todays_earnings = tonumber(stats.todays_earnings) or 0,
                        total_earnings = tonumber(stats.total_earnings) or 0,
                        success_rate = success_rate,
                        average_rating = tonumber(stats.rating) or 0,
                        total_deliveries = stats.total_deliveries or 0,
                        successful_deliveries = stats.successful_deliveries or 0
                    },

                    -- Capacity info
                    capacity = {
                        current = stats.current_active_orders or 0,
                        maximum = stats.max_daily_capacity or 0,
                        percentage = capacity_percentage,
                        available = (stats.max_daily_capacity or 0) - (stats.current_active_orders or 0)
                    },

                    -- Status
                    status = {
                        is_verified = stats.is_verified,
                        is_active = stats.is_active,
                        can_accept_orders = stats.is_verified and stats.is_active and
                                           stats.current_active_orders < stats.max_daily_capacity,
                        verification_required = not stats.is_verified,
                        verification_message = not stats.is_verified
                            and "Your account is pending verification. Upload required documents to get verified."
                            or nil
                    },

                    -- Notifications
                    notifications = {
                        unread_count = tonumber(stats.unread_notifications) or 0
                    }
                }
            }
        end)
    }))

    --[[
        Get Nearby Available Orders

        Uses geospatial queries to find orders within the partner's service radius.
        Orders are sorted by distance (nearest first).
    ]]--
    app:match("get_nearby_orders_geo", "/api/v2/delivery-partner/nearby-orders", respond_to({
        GET = AuthMiddleware.requireAuth(function(self)
            local user = db.query("SELECT id FROM users WHERE uuid = ?", self.current_user.uuid)[1]
            if not user then
                return { status = 404, json = { error = "User not found" } }
            end

            local delivery_partner = db.query([[
                SELECT * FROM delivery_partners WHERE user_id = ?
            ]], user.id)[1]

            if not delivery_partner then
                return { status = 404, json = { error = "Delivery partner profile not found" } }
            end

            -- Check eligibility
            if not delivery_partner.is_verified then
                return {
                    json = {
                        orders = {},
                        verification_required = true,
                        verification_status = "not_verified",
                        message = "Your account needs to be verified to see orders",
                        action = {
                            type = "verify_account",
                            url = "/api/v2/delivery-partners/verification/status",
                            message = "Upload required documents to get verified and start accepting orders"
                        }
                    }
                }
            end

            if not delivery_partner.is_active then
                return {
                    json = {
                        orders = {},
                        message = "Your account is currently inactive"
                    }
                }
            end

            if delivery_partner.current_active_orders >= delivery_partner.max_daily_capacity then
                return {
                    json = {
                        orders = {},
                        message = "You are at full capacity. Complete current deliveries to see more orders."
                    }
                }
            end

            if not delivery_partner.latitude or not delivery_partner.longitude then
                return {
                    json = {
                        orders = {},
                        message = "Please update your location to see nearby orders"
                    }
                }
            end

            -- Find nearby orders using PostGIS
            local orders = db.query([[
                SELECT
                    o.id,
                    o.uuid,
                    o.order_number,
                    o.total_amount,
                    o.status,
                    o.delivery_latitude,
                    o.delivery_longitude,
                    o.shipping_address,
                    o.created_at,
                    s.id as store_id,
                    s.name as store_name,
                    s.slug as store_slug,
                    s.contact_phone as store_phone,
                    s.address as store_address,
                    ROUND(
                        ST_Distance(
                            ST_SetSRID(ST_MakePoint(?, ?), 4326)::geography,
                            ST_SetSRID(ST_MakePoint(o.delivery_longitude, o.delivery_latitude), 4326)::geography
                        ) / 1000,
                        2
                    ) as distance_km,
                    calculate_delivery_fee(?,
                        ST_Distance(
                            ST_SetSRID(ST_MakePoint(?, ?), 4326)::geography,
                            ST_SetSRID(ST_MakePoint(o.delivery_longitude, o.delivery_latitude), 4326)::geography
                        ) / 1000,
                        o.total_amount
                    ) as estimated_delivery_fee
                FROM orders o
                INNER JOIN stores s ON o.store_id = s.id
                LEFT JOIN order_delivery_assignments oda ON o.id = oda.order_id
                LEFT JOIN delivery_requests dr ON o.id = dr.order_id
                    AND dr.delivery_partner_id = ?
                    AND dr.status = 'pending'
                WHERE o.status IN ('confirmed', 'ready_for_pickup', 'packing')
                AND oda.id IS NULL
                AND dr.id IS NULL
                AND o.delivery_latitude IS NOT NULL
                AND o.delivery_longitude IS NOT NULL
                AND ST_DWithin(
                    ST_SetSRID(ST_MakePoint(?, ?), 4326)::geography,
                    ST_SetSRID(ST_MakePoint(o.delivery_longitude, o.delivery_latitude), 4326)::geography,
                    ? * 1000
                )
                ORDER BY distance_km ASC
                LIMIT 50
            ]],
            delivery_partner.longitude, delivery_partner.latitude,
            delivery_partner.id,
            delivery_partner.longitude, delivery_partner.latitude,
            delivery_partner.id,
            delivery_partner.longitude, delivery_partner.latitude,
            delivery_partner.service_radius_km
            )

            -- Parse shipping addresses
            for _, order in ipairs(orders) do
                if order.shipping_address then
                    local ok, parsed = pcall(cjson.decode, order.shipping_address)
                    if ok then
                        order.shipping_address = parsed
                    end
                end
            end

            return {
                json = {
                    orders = orders or {},
                    partner_location = {
                        latitude = tonumber(delivery_partner.latitude),
                        longitude = tonumber(delivery_partner.longitude),
                        service_radius_km = tonumber(delivery_partner.service_radius_km)
                    },
                    count = #orders
                }
            }
        end)
    }))

    --[[
        Get Delivery Partner Notifications
    ]]--
    app:match("get_delivery_notifications", "/api/v2/delivery-partner/notifications", respond_to({
        GET = AuthMiddleware.requireAuth(function(self)
            local user = db.query("SELECT id FROM users WHERE uuid = ?", self.current_user.uuid)[1]
            if not user then
                return { status = 404, json = { error = "User not found" } }
            end

            local delivery_partner = db.query("SELECT id FROM delivery_partners WHERE user_id = ?", user.id)[1]
            if not delivery_partner then
                return { status = 404, json = { error = "Delivery partner profile not found" } }
            end

            local notifications = DeliveryNotificationService.getUnreadNotifications(delivery_partner.id)

            -- Parse shipping addresses for each notification
            for _, notification in ipairs(notifications) do
                if notification.shipping_address then
                    local ok, parsed = pcall(cjson.decode, notification.shipping_address)
                    if ok then
                        notification.shipping_address = parsed
                    end
                end
            end

            return {
                json = {
                    notifications = notifications,
                    count = #notifications
                }
            }
        end)
    }))

    --[[
        Mark Notification as Read
    ]]--
    app:match("mark_notification_read", "/api/v2/delivery-partner/notifications/:id/read", respond_to({
        PUT = AuthMiddleware.requireAuth(function(self)
            local notification_id = tonumber(self.params.id)
            if not notification_id then
                return { status = 400, json = { error = "Invalid notification ID" } }
            end

            local user = db.query("SELECT id FROM users WHERE uuid = ?", self.current_user.uuid)[1]
            if not user then
                return { status = 404, json = { error = "User not found" } }
            end

            local delivery_partner = db.query("SELECT id FROM delivery_partners WHERE user_id = ?", user.id)[1]
            if not delivery_partner then
                return { status = 404, json = { error = "Delivery partner profile not found" } }
            end

            local success = DeliveryNotificationService.markAsRead(notification_id, delivery_partner.id)

            if not success then
                return { status = 500, json = { error = "Failed to mark notification as read" } }
            end

            return {
                json = {
                    message = "Notification marked as read"
                }
            }
        end)
    }))

    --[[
        Request to Deliver an Order

        When a delivery partner sees an order notification and wants to deliver it,
        they can send a request to the store owner.
    ]]--
    app:match("request_to_deliver", "/api/v2/delivery-partner/request-delivery", respond_to({
        POST = AuthMiddleware.requireAuth(function(self)
            local params = self.params
            local order_id = tonumber(params.order_id)

            if not order_id then
                return { status = 400, json = { error = "order_id is required" } }
            end

            local user = db.query("SELECT id FROM users WHERE uuid = ?", self.current_user.uuid)[1]
            if not user then
                return { status = 404, json = { error = "User not found" } }
            end

            local delivery_partner = db.query("SELECT * FROM delivery_partners WHERE user_id = ?", user.id)[1]
            if not delivery_partner then
                return { status = 404, json = { error = "Delivery partner profile not found" } }
            end

            -- Verify eligibility
            if not delivery_partner.is_verified or not delivery_partner.is_active then
                return { status = 403, json = { error = "Your account is not eligible to accept orders" } }
            end

            if delivery_partner.current_active_orders >= delivery_partner.max_daily_capacity then
                return { status = 403, json = { error = "You are at full capacity" } }
            end

            -- Get order details
            local order = db.query("SELECT * FROM orders WHERE id = ?", order_id)[1]
            if not order then
                return { status = 404, json = { error = "Order not found" } }
            end

            -- Check if order already has an assignment
            local existing_assignment = db.query(
                "SELECT * FROM order_delivery_assignments WHERE order_id = ?",
                order_id
            )[1]

            if existing_assignment then
                return { status = 400, json = { error = "Order already has a delivery assignment" } }
            end

            -- Check if partner already sent a request
            local existing_request = db.query(
                "SELECT * FROM delivery_requests WHERE order_id = ? AND delivery_partner_id = ?",
                order_id,
                delivery_partner.id
            )[1]

            if existing_request then
                return { status = 400, json = { error = "You already sent a request for this order" } }
            end

            -- Calculate delivery fee
            local distance_km = 0
            local delivery_fee = delivery_partner.base_charge

            if order.delivery_latitude and order.delivery_longitude and
               delivery_partner.latitude and delivery_partner.longitude then
                distance_km = db.query([[
                    SELECT ROUND(
                        ST_Distance(
                            ST_SetSRID(ST_MakePoint(?, ?), 4326)::geography,
                            ST_SetSRID(ST_MakePoint(?, ?), 4326)::geography
                        ) / 1000,
                        2
                    ) as distance
                ]],
                delivery_partner.longitude, delivery_partner.latitude,
                order.delivery_longitude, order.delivery_latitude
                )[1].distance

                delivery_fee = db.query([[
                    SELECT calculate_delivery_fee(?, ?, ?)
                ]], delivery_partner.id, distance_km, order.total_amount)[1].calculate_delivery_fee
            end

            -- Create delivery request
            local Global = require("helper.global")
            local timestamp = Global.getCurrentTimestamp()
            local expires_at = db.format_date(os.time() + (24 * 60 * 60)) -- 24 hours

            local request = db.query([[
                INSERT INTO delivery_requests (
                    uuid, order_id, delivery_partner_id,
                    request_type, status, proposed_fee,
                    message, expires_at, created_at, updated_at
                ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                RETURNING *
            ]],
            Global.generateStaticUUID(),
            order_id,
            delivery_partner.id,
            "partner_to_seller",
            "pending",
            delivery_fee,
            params.message or string.format("I can deliver this order for ₹%.2f (%.2f km)", delivery_fee, distance_km),
            expires_at,
            timestamp,
            timestamp
            )[1]

            ngx.log(ngx.INFO, string.format(
                "Delivery request created: Partner %s requested order %d (fee: ₹%.2f, distance: %.2f km)",
                delivery_partner.company_name,
                order_id,
                delivery_fee,
                distance_km
            ))

            return {
                json = {
                    message = "Delivery request sent successfully",
                    request = {
                        uuid = request.uuid,
                        order_id = order_id,
                        proposed_fee = tonumber(request.proposed_fee),
                        distance_km = distance_km,
                        status = request.status,
                        expires_at = request.expires_at
                    }
                },
                status = 201
            }
        end)
    }))
end
