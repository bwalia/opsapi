--[[
    Professional Delivery Management System

    Complete order-to-delivery workflow:
    1. Delivery partner views available orders
    2. Accepts an order
    3. System creates order_delivery_assignment
    4. Partner updates delivery status
    5. Completes delivery

    Author: Senior Backend Engineer
    Date: 2025-01-26
]]--

local respond_to = require("lapis.application").respond_to
local AuthMiddleware = require("middleware.auth")
local db = require("lapis.db")
local cjson = require("cjson")

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

return function(app)

    --[[
        Accept an Order
        POST /api/v2/delivery/orders/:order_id/accept

        Creates an order_delivery_assignment record
        Updates delivery partner's current_active_orders
        Updates order status
    ]]--
    app:match("accept_delivery_order", "/api/v2/delivery/orders/:order_id/accept", respond_to({
        POST = AuthMiddleware.requireAuth(function(self)
            local params = parse_json_body()
            if not params or not next(params) then
                params = self.params
            end

            local order_id = tonumber(self.params.order_id)
            if not order_id then
                return { json = { error = "Invalid order ID" }, status = 400 }
            end

            -- Get user and delivery partner
            local user = db.query("SELECT id FROM users WHERE uuid = ?", self.current_user.uuid)[1]
            if not user then
                return { status = 404, json = { error = "User not found" } }
            end

            local delivery_partner = db.query("SELECT * FROM delivery_partners WHERE user_id = ?", user.id)[1]
            if not delivery_partner then
                return { status = 404, json = { error = "Delivery partner profile not found" } }
            end

            -- Check if partner is verified and active
            if not delivery_partner.is_verified or not delivery_partner.is_active then
                return { json = { error = "Your account must be verified and active to accept orders" }, status = 403 }
            end

            -- Check if partner has capacity
            if delivery_partner.current_active_orders >= delivery_partner.max_daily_capacity then
                return { json = { error = "You have reached maximum capacity for today" }, status = 403 }
            end

            -- Get order details
            local order = db.query("SELECT * FROM orders WHERE id = ?", order_id)[1]
            if not order then
                return { json = { error = "Order not found" }, status = 404 }
            end

            -- Check if order is already assigned
            local existing_assignment = db.query([[
                SELECT id FROM order_delivery_assignments
                WHERE order_id = ? AND status IN ('pending', 'accepted', 'picked_up', 'in_transit')
            ]], order_id)[1]

            if existing_assignment then
                return { json = { error = "Order is already assigned to another delivery partner" }, status = 409 }
            end

            -- Check if order status is eligible for delivery
            if order.status ~= 'pending' and order.status ~= 'confirmed' and order.status ~= 'processing' then
                return { json = { error = "Order is not available for delivery" }, status = 400 }
            end

            -- Begin transaction
            local success, result = pcall(function()
                -- Calculate delivery fee based on distance
                local delivery_fee = delivery_partner.base_charge or 0

                -- If we have distance, add per_km charge
                if params.distance_km and delivery_partner.per_km_charge then
                    delivery_fee = delivery_fee + (params.distance_km * delivery_partner.per_km_charge)
                end

                -- Add percentage charge
                if delivery_partner.percentage_charge then
                    delivery_fee = delivery_fee + ((order.total_amount * delivery_partner.percentage_charge) / 100)
                end

                -- Create assignment (returns table with id and uuid)
                local assignment_result = db.insert("order_delivery_assignments", {
                    uuid = db.raw("gen_random_uuid()"),
                    order_id = order_id,
                    delivery_partner_id = delivery_partner.id,
                    status = "accepted",
                    delivery_fee = delivery_fee,
                    assigned_at = db.raw("NOW()"),
                    accepted_at = db.raw("NOW()"),
                    created_at = db.raw("NOW()"),
                    updated_at = db.raw("NOW()")
                }, "id", "uuid")

                -- Handle return value - could be table or single value depending on Lapis version
                local assignment_id, assignment_uuid
                if type(assignment_result) == "table" then
                    assignment_id = assignment_result.id
                    assignment_uuid = assignment_result.uuid
                else
                    -- Old behavior - returns first column only
                    assignment_id = assignment_result
                    -- Need to fetch UUID
                    local fetched = db.query("SELECT uuid FROM order_delivery_assignments WHERE id = ?", assignment_id)[1]
                    assignment_uuid = fetched and fetched.uuid or nil
                end

                -- Update delivery partner's active orders count
                db.query([[
                    UPDATE delivery_partners
                    SET current_active_orders = current_active_orders + 1,
                        updated_at = NOW()
                    WHERE id = ?
                ]], delivery_partner.id)

                -- Update order status
                db.query([[
                    UPDATE orders
                    SET status = 'confirmed',
                        delivery_partner_id = ?,
                        updated_at = NOW()
                    WHERE id = ?
                ]], delivery_partner.id, order_id)

                -- Create order status history
                db.insert("order_status_history", {
                    order_id = order_id,
                    status = "confirmed",
                    note = "Accepted by delivery partner: " .. delivery_partner.company_name,
                    created_at = db.raw("NOW()")
                })

                ngx.log(ngx.INFO, string.format("Order #%d accepted by delivery partner #%d (assignment #%d)",
                    order_id, delivery_partner.id, assignment_id))

                return {
                    assignment_id = assignment_id,
                    assignment_uuid = assignment_uuid,
                    delivery_fee = delivery_fee,
                    order_id = order_id,
                    status = "accepted"
                }
            end)

            if not success then
                ngx.log(ngx.ERR, "Error accepting order: " .. tostring(result))
                return { json = { error = "Failed to accept order: " .. tostring(result) }, status = 500 }
            end

            return { json = { success = true, data = result } }
        end)
    }))

    --[[
        Update Delivery Status
        PUT /api/v2/delivery/assignments/:assignment_id/status

        Updates the delivery status:
        - accepted -> picked_up
        - picked_up -> in_transit
        - in_transit -> delivered
        - any -> cancelled
    ]]--
    app:match("update_delivery_status", "/api/v2/delivery/assignments/:assignment_id/status", respond_to({
        PUT = AuthMiddleware.requireAuth(function(self)
            local params = parse_json_body()
            if not params or not next(params) then
                params = self.params
            end

            local assignment_id = tonumber(self.params.assignment_id)
            local new_status = params.status
            local note = params.note or ""

            if not assignment_id or not new_status then
                return { json = { error = "Assignment ID and status are required" }, status = 400 }
            end

            -- Valid statuses
            local valid_statuses = {
                accepted = true,
                picked_up = true,
                in_transit = true,
                delivered = true,
                cancelled = true,
                failed = true
            }

            if not valid_statuses[new_status] then
                return { json = { error = "Invalid status" }, status = 400 }
            end

            -- Get user and delivery partner
            local user = db.query("SELECT id FROM users WHERE uuid = ?", self.current_user.uuid)[1]
            if not user then
                return { status = 404, json = { error = "User not found" } }
            end

            local delivery_partner = db.query("SELECT * FROM delivery_partners WHERE user_id = ?", user.id)[1]
            if not delivery_partner then
                return { status = 404, json = { error = "Delivery partner profile not found" } }
            end

            -- Get assignment
            local assignment = db.query([[
                SELECT * FROM order_delivery_assignments
                WHERE id = ? AND delivery_partner_id = ?
            ]], assignment_id, delivery_partner.id)[1]

            if not assignment then
                return { json = { error = "Assignment not found or does not belong to you" }, status = 404 }
            end

            -- Validate status transition
            local current_status = assignment.status
            local valid_transitions = {
                accepted = { picked_up = true, cancelled = true },
                picked_up = { in_transit = true, cancelled = true },
                in_transit = { delivered = true, failed = true, cancelled = true },
                delivered = {},  -- Terminal state
                cancelled = {},  -- Terminal state
                failed = {}      -- Terminal state
            }

            if not valid_transitions[current_status] then
                return { json = { error = "Cannot update from current status: " .. current_status }, status = 400 }
            end

            if not valid_transitions[current_status][new_status] then
                return { json = { error = string.format("Invalid transition from %s to %s", current_status, new_status) }, status = 400 }
            end

            -- Begin transaction
            local success, result = pcall(function()
                -- Update assignment
                local update_fields = {
                    status = new_status,
                    updated_at = db.raw("NOW()")
                }

                -- Set timestamp fields
                if new_status == "picked_up" then
                    update_fields.picked_up_at = db.raw("NOW()")
                elseif new_status == "in_transit" then
                    update_fields.in_transit_at = db.raw("NOW()")
                elseif new_status == "delivered" then
                    update_fields.delivered_at = db.raw("NOW()")
                    update_fields.delivery_proof_url = params.proof_url
                elseif new_status == "cancelled" or new_status == "failed" then
                    update_fields.cancellation_reason = note
                end

                db.update("order_delivery_assignments", update_fields, "id = " .. assignment_id)

                -- Update order status
                local order_status_map = {
                    accepted = "confirmed",
                    picked_up = "shipped",
                    in_transit = "in_transit",
                    delivered = "delivered",
                    cancelled = "cancelled",
                    failed = "failed"
                }

                local order_status = order_status_map[new_status] or "processing"

                db.query([[
                    UPDATE orders
                    SET status = ?,
                        updated_at = NOW()
                    WHERE id = ?
                ]], order_status, assignment.order_id)

                -- Create order status history
                db.insert("order_status_history", {
                    order_id = assignment.order_id,
                    status = order_status,
                    note = note or ("Delivery status updated to: " .. new_status),
                    created_at = db.raw("NOW()")
                })

                -- If delivered or cancelled, update delivery partner active orders
                if new_status == "delivered" or new_status == "cancelled" or new_status == "failed" then
                    db.query([[
                        UPDATE delivery_partners
                        SET current_active_orders = GREATEST(0, current_active_orders - 1),
                            updated_at = NOW()
                        WHERE id = ?
                    ]], delivery_partner.id)

                    -- If delivered, increment successful deliveries
                    if new_status == "delivered" then
                        db.query([[
                            UPDATE delivery_partners
                            SET total_deliveries = total_deliveries + 1,
                                successful_deliveries = successful_deliveries + 1,
                                updated_at = NOW()
                            WHERE id = ?
                        ]], delivery_partner.id)
                    end
                end

                ngx.log(ngx.INFO, string.format("Assignment #%d status updated from %s to %s",
                    assignment_id, current_status, new_status))

                return {
                    assignment_id = assignment_id,
                    order_id = assignment.order_id,
                    old_status = current_status,
                    new_status = new_status,
                    timestamp = os.time()
                }
            end)

            if not success then
                ngx.log(ngx.ERR, "Error updating delivery status: " .. tostring(result))
                return { json = { error = "Failed to update status: " .. tostring(result) }, status = 500 }
            end

            return { json = { success = true, data = result } }
        end)
    }))

    --[[
        Get Active Deliveries
        GET /api/v2/delivery/active

        Returns all active deliveries for the current delivery partner
    ]]--
    app:match("get_active_deliveries", "/api/v2/delivery/active", respond_to({
        GET = AuthMiddleware.requireAuth(function(self)
            -- Get user and delivery partner
            local user = db.query("SELECT id FROM users WHERE uuid = ?", self.current_user.uuid)[1]
            if not user then
                return { status = 404, json = { error = "User not found" } }
            end

            local delivery_partner = db.query("SELECT * FROM delivery_partners WHERE user_id = ?", user.id)[1]
            if not delivery_partner then
                return { status = 404, json = { error = "Delivery partner profile not found" } }
            end

            -- Get active assignments
            local assignments = db.query([[
                SELECT
                    oda.id,
                    oda.uuid,
                    oda.order_id,
                    oda.status,
                    oda.delivery_fee,
                    oda.assigned_at,
                    oda.accepted_at,
                    oda.picked_up_at,
                    oda.in_transit_at,
                    oda.delivered_at,
                    o.order_number,
                    o.total_amount,
                    o.shipping_address,
                    o.billing_address,
                    o.delivery_latitude,
                    o.delivery_longitude,
                    o.shipping_address::json->>'name' as customer_name,
                    o.shipping_address::json->>'address1' as delivery_address,
                    o.shipping_address::json->>'city' as delivery_city,
                    o.shipping_address::json->>'state' as delivery_state,
                    o.shipping_address::json->>'zip' as delivery_zip,
                    o.created_at as order_created_at,
                    s.name as store_name,
                    s.slug as store_slug,
                    s.contact_phone as store_phone
                FROM order_delivery_assignments oda
                INNER JOIN orders o ON oda.order_id = o.id
                INNER JOIN stores s ON o.store_id = s.id
                WHERE oda.delivery_partner_id = ?
                AND oda.status IN ('accepted', 'picked_up', 'in_transit')
                ORDER BY oda.accepted_at DESC
            ]], delivery_partner.id)

            return { json = { deliveries = assignments or {} } }
        end)
    }))

    --[[
        Get Delivery History
        GET /api/v2/delivery/history

        Returns completed and cancelled deliveries
    ]]--
    app:match("get_delivery_history", "/api/v2/delivery/history", respond_to({
        GET = AuthMiddleware.requireAuth(function(self)
            local params = self.params
            local limit = tonumber(params.limit) or 50
            local offset = tonumber(params.offset) or 0

            -- Get user and delivery partner
            local user = db.query("SELECT id FROM users WHERE uuid = ?", self.current_user.uuid)[1]
            if not user then
                return { status = 404, json = { error = "User not found" } }
            end

            local delivery_partner = db.query("SELECT * FROM delivery_partners WHERE user_id = ?", user.id)[1]
            if not delivery_partner then
                return { status = 404, json = { error = "Delivery partner profile not found" } }
            end

            -- Get completed/cancelled assignments
            local assignments = db.query([[
                SELECT
                    oda.id,
                    oda.uuid,
                    oda.order_id,
                    oda.status,
                    oda.delivery_fee,
                    oda.assigned_at,
                    oda.delivered_at,
                    o.order_number,
                    o.total_amount,
                    o.shipping_address::json->>'name' as customer_name,
                    o.shipping_address::json->>'city' as delivery_city,
                    o.created_at as order_created_at,
                    s.name as store_name
                FROM order_delivery_assignments oda
                INNER JOIN orders o ON oda.order_id = o.id
                INNER JOIN stores s ON o.store_id = s.id
                WHERE oda.delivery_partner_id = ?
                AND oda.status IN ('delivered', 'cancelled', 'failed')
                ORDER BY oda.updated_at DESC
                LIMIT ? OFFSET ?
            ]], delivery_partner.id, limit, offset)

            -- Get total count
            local count = db.query([[
                SELECT COUNT(*) as total
                FROM order_delivery_assignments
                WHERE delivery_partner_id = ?
                AND status IN ('delivered', 'cancelled', 'failed')
            ]], delivery_partner.id)[1].total

            return { json = {
                deliveries = assignments or {},
                total = count,
                limit = limit,
                offset = offset
            } }
        end)
    }))

end
