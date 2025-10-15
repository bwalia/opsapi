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
                return { json = { orders = {}, message = "You are at full capacity" } }
            end

            -- Get partner's service areas
            local areas = db.query([[
                SELECT DISTINCT city, state, country
                FROM delivery_partner_areas
                WHERE delivery_partner_id = ? AND is_active = true
            ]], delivery_partner.id)

            if not areas or #areas == 0 then
                return { json = { orders = {}, message = "Please add service areas to your profile" } }
            end

            -- Build query to find orders in service areas
            -- Note: shipping_address is stored as JSON, so we need to extract city and state
            local area_conditions = {}
            for _, area in ipairs(areas) do
                table.insert(area_conditions, string.format(
                    "(shipping_address::json->>'city' = %s AND shipping_address::json->>'state' = %s)",
                    db.escape_literal(area.city),
                    db.escape_literal(area.state)
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
                    shipping_address::json->>'city' as delivery_city,
                    shipping_address::json->>'state' as delivery_state,
                    shipping_address::json->>'postal_code' as delivery_postal_code,
                    shipping_address::json->>'address' as delivery_address,
                    o.created_at,
                    s.name as store_name,
                    s.slug as store_slug,
                    s.contact_phone as store_phone
                FROM orders o
                INNER JOIN stores s ON o.store_id = s.id
                LEFT JOIN order_delivery_assignments oda ON o.id = oda.order_id
                LEFT JOIN delivery_requests dr ON o.id = dr.order_id
                    AND dr.delivery_partner_id = %d
                    AND dr.status = 'pending'
                WHERE o.status IN ('pending', 'confirmed', 'accepted', 'preparing', 'packing', 'processing')
                AND oda.id IS NULL
                AND dr.id IS NULL
                AND (%s)
                ORDER BY o.created_at DESC
                LIMIT 50
            ]], delivery_partner.id, table.concat(area_conditions, " OR "))

            local orders = db.query(query)

            return { json = { orders = orders or {} } }
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
            local request = db.insert("delivery_requests", {
                uuid = require("utils.global").generateUUID(),
                order_id = params.order_id,
                delivery_partner_id = delivery_partner.id,
                request_type = "partner_to_seller",
                status = "pending",
                proposed_fee = proposed_fee,
                message = params.message,
                expires_at = db.format_date(os.time() + 86400),  -- 24 hours
                created_at = db.format_date(),
                updated_at = db.format_date()
            }, "id")

            local created_request = db.query("SELECT * FROM delivery_requests WHERE id = ?", request.id)[1]

            return { json = {
                message = "Delivery request created successfully",
                request = created_request
            }}
        end)
    }))
end
