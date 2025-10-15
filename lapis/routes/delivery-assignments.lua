local lapis = require("lapis")
local respond_to = require("lapis.application").respond_to
local AuthMiddleware = require("middleware.auth")
local OrderDeliveryAssignmentQueries = require("queries.OrderDeliveryAssignmentQueries")
local DeliveryPartnerQueries = require("queries.DeliveryPartnerQueries")
local cjson = require("cjson")
local db = require("lapis.db")

return function(app)
    -- Create delivery assignment (seller assigns partner to order)
    app:match("/api/v2/delivery-assignments", respond_to({
        POST = AuthMiddleware.requireAuth(function(self)
            -- Get user ID from current_user
            local user = db.query("SELECT id FROM users WHERE uuid = ?", self.current_user.uuid)[1]
            if not user then
                return { status = 404, json = { error = "User not found" } }
            end
            local user_id = user.id

            local params = self.params
            if not params.order_id or not params.delivery_partner_id then
                return { status = 400, json = { error = "order_id and delivery_partner_id are required" } }
            end

            -- Verify user owns the store for this order
            local order = db.query([[
                SELECT o.*, s.user_id as store_owner_id
                FROM orders o
                INNER JOIN stores s ON o.store_id = s.id
                WHERE o.id = ?
            ]], params.order_id)[1]

            if not order then
                return { status = 404, json = { error = "Order not found" } }
            end

            if order.store_owner_id ~= user_id then
                return { status = 403, json = { error = "You don't have permission to assign delivery for this order" } }
            end

            -- Check if order already has an assignment
            local existing = db.query("SELECT * FROM order_delivery_assignments WHERE order_id = ?", params.order_id)[1]
            if existing then
                return { status = 400, json = { error = "Order already has a delivery assignment" } }
            end

            -- Get delivery partner details
            local delivery_partner = db.query("SELECT * FROM delivery_partners WHERE id = ?", params.delivery_partner_id)[1]
            if not delivery_partner then
                return { status = 404, json = { error = "Delivery partner not found" } }
            end

            -- Check capacity
            if delivery_partner.current_active_orders >= delivery_partner.max_daily_capacity then
                return { status = 400, json = { error = "Delivery partner is at full capacity" } }
            end

            -- Create assignment
            local success, assignment = pcall(function()
                return OrderDeliveryAssignmentQueries.create({
                    order_id = params.order_id,
                    delivery_partner_id = params.delivery_partner_id,
                    assignment_type = "seller_assigned",
                    delivery_fee = params.delivery_fee or 0,
                    pickup_address = params.pickup_address,
                    delivery_address = params.delivery_address,
                    pickup_instructions = params.pickup_instructions,
                    delivery_instructions = params.delivery_instructions,
                    estimated_pickup_time = params.estimated_pickup_time,
                    estimated_delivery_time = params.estimated_delivery_time,
                    distance_km = params.distance_km or 0
                })
            end)

            if not success then
                ngx.log(ngx.ERR, "Failed to create delivery assignment: " .. tostring(assignment))
                return { status = 500, json = { error = "Failed to create delivery assignment" } }
            end

            -- Update order with delivery partner
            db.update("orders", {
                delivery_partner_id = params.delivery_partner_id,
                updated_at = db.format_date()
            }, "id = ?", params.order_id)

            -- Increment partner's active orders
            db.update("delivery_partners", {
                current_active_orders = db.raw("current_active_orders + 1")
            }, "id = ?", params.delivery_partner_id)

            return { json = {
                message = "Delivery assignment created successfully",
                assignment = assignment
            }}
        end)
    }))

    -- Get delivery assignment by UUID
    app:match("/api/v2/delivery-assignments/:uuid", respond_to({
        GET = AuthMiddleware.requireAuth(function(self)
            local uuid = self.params.uuid
            -- Get user ID from current_user
            local user = db.query("SELECT id FROM users WHERE uuid = ?", self.current_user.uuid)[1]
            if not user then
                return { status = 404, json = { error = "User not found" } }
            end
            local user_id = user.id

            local success, assignment = pcall(function()
                return OrderDeliveryAssignmentQueries.getWithDetails(uuid)
            end)

            if not success or not assignment then
                return { status = 404, json = { error = "Assignment not found" } }
            end

            -- Verify user has permission (store owner or delivery partner)
            if assignment.store_owner_id ~= user_id and assignment.delivery_partner_user_id ~= user_id then
                return { status = 403, json = { error = "You don't have permission to view this assignment" } }
            end

            return { json = { assignment = assignment } }
        end)
    }))

    -- Update delivery assignment status
    app:match("/api/v2/delivery-assignments/:uuid/status", respond_to({
        PUT = AuthMiddleware.requireAuth(function(self)
            local uuid = self.params.uuid
            -- Get user ID from current_user
            local user = db.query("SELECT id FROM users WHERE uuid = ?", self.current_user.uuid)[1]
            if not user then
                return { status = 404, json = { error = "User not found" } }
            end
            local user_id = user.id
            local params = self.params

            if not params.status then
                return { status = 400, json = { error = "status is required" } }
            end

            -- Get assignment with details
            local success, assignment = pcall(function()
                return OrderDeliveryAssignmentQueries.getWithDetails(uuid)
            end)

            if not success or not assignment then
                return { status = 404, json = { error = "Assignment not found" } }
            end

            -- Verify user is the delivery partner
            if assignment.delivery_partner_user_id ~= user_id then
                return { status = 403, json = { error = "Only the assigned delivery partner can update status" } }
            end

            -- Validate status transitions
            local valid_statuses = {"pending", "accepted", "rejected", "picked_up", "in_transit", "delivered", "failed"}
            local is_valid = false
            for _, status in ipairs(valid_statuses) do
                if status == params.status then
                    is_valid = true
                    break
                end
            end

            if not is_valid then
                return { status = 400, json = { error = "Invalid status" } }
            end

            -- Update assignment status
            local additional_data = {}
            if params.proof_of_delivery then
                additional_data.proof_of_delivery = params.proof_of_delivery
            end
            if params.notes then
                additional_data.notes = params.notes
            end

            local success, updated_assignment = pcall(function()
                return OrderDeliveryAssignmentQueries.updateStatus(assignment.id, params.status, additional_data)
            end)

            if not success then
                ngx.log(ngx.ERR, "Failed to update assignment status: " .. tostring(updated_assignment))
                return { status = 500, json = { error = "Failed to update assignment status" } }
            end

            -- Update order status based on delivery status
            local order_status_map = {
                picked_up = "shipping",
                in_transit = "shipping",
                delivered = "delivered",
                failed = "cancelled"
            }

            if order_status_map[params.status] then
                db.update("orders", {
                    status = order_status_map[params.status],
                    updated_at = db.format_date()
                }, "id = ?", assignment.order_id)
            end

            -- If delivered or failed, decrement partner's active orders
            if params.status == "delivered" or params.status == "failed" then
                db.update("delivery_partners", {
                    current_active_orders = db.raw("GREATEST(current_active_orders - 1, 0)")
                }, "id = ?", assignment.delivery_partner_id)

                -- If delivered, increment successful deliveries
                if params.status == "delivered" then
                    db.update("delivery_partners", {
                        total_deliveries = db.raw("total_deliveries + 1"),
                        successful_deliveries = db.raw("successful_deliveries + 1")
                    }, "id = ?", assignment.delivery_partner_id)
                end
            end

            return { json = {
                message = "Assignment status updated successfully",
                assignment = updated_assignment
            }}
        end)
    }))

    -- Get all assignments for delivery partner
    app:match("/api/v2/delivery-partner/assignments", respond_to({
        GET = AuthMiddleware.requireAuth(function(self)
            -- Get user ID from current_user
            local user = db.query("SELECT id FROM users WHERE uuid = ?", self.current_user.uuid)[1]
            if not user then
                return { status = 404, json = { error = "User not found" } }
            end
            local user_id = user.id
            local status = self.params.status

            -- Get delivery partner ID
            local delivery_partner = db.query("SELECT * FROM delivery_partners WHERE user_id = ?", user_id)[1]
            if not delivery_partner then
                return { status = 404, json = { error = "Delivery partner profile not found" } }
            end

            local success, assignments = pcall(function()
                return OrderDeliveryAssignmentQueries.getByDeliveryPartner(delivery_partner.id, status)
            end)

            if not success then
                ngx.log(ngx.ERR, "Failed to get assignments: " .. tostring(assignments))
                return { status = 500, json = { error = "Failed to fetch assignments" } }
            end

            return { json = { assignments = assignments or {} } }
        end)
    }))

    -- Get assignment statistics for delivery partner
    app:match("/api/v2/delivery-partner/assignment-stats", respond_to({
        GET = AuthMiddleware.requireAuth(function(self)
            -- Get user ID from current_user
            local user = db.query("SELECT id FROM users WHERE uuid = ?", self.current_user.uuid)[1]
            if not user then
                return { status = 404, json = { error = "User not found" } }
            end
            local user_id = user.id

            -- Get delivery partner ID
            local delivery_partner = db.query("SELECT * FROM delivery_partners WHERE user_id = ?", user_id)[1]
            if not delivery_partner then
                return { status = 404, json = { error = "Delivery partner profile not found" } }
            end

            local success, stats = pcall(function()
                return OrderDeliveryAssignmentQueries.getStatistics(delivery_partner.id)
            end)

            if not success then
                ngx.log(ngx.ERR, "Failed to get stats: " .. tostring(stats))
                return { status = 500, json = { error = "Failed to fetch statistics" } }
            end

            return { json = { stats = stats } }
        end)
    }))
end
