local respond_to = require("lapis.application").respond_to
local OrderQueries = require "queries.OrderQueries"
local AuthMiddleware = require "middleware.auth"
local db = require("lapis.db")

return function(app)
    -- Get all orders (admin only)
    app:match("orders", "/api/v2/orders", respond_to({
        GET = AuthMiddleware.requireRole("admin", function(self)
            return { json = OrderQueries.all(self.params) }
        end),
        POST = AuthMiddleware.requireAuth(function(self)
            return { json = OrderQueries.create(self.params), status = 201 }
        end)
    }))

    -- Get orders for a specific store (store owner or admin)
    app:match("store_orders", "/api/v2/stores/:store_id/orders", respond_to({
        GET = AuthMiddleware.requireAuth(function(self)
            local store_id = self.params.store_id

            -- Get user's store ownership or admin status
            local user_stores = db.select("id from stores where uuid = ? and user_id = (select id from users where uuid = ?)",
                store_id, self.current_user.uuid)

            if not user_stores or #user_stores == 0 then
                -- Check if user is admin
                local UserQueries = require("queries.UserQueries")
                local user_data = UserQueries.show(self.current_user.uuid)
                local is_admin = false
                if user_data and user_data.roles then
                    for _, role in ipairs(user_data.roles) do
                        if role.name == "admin" then
                            is_admin = true
                            break
                        end
                    end
                end

                if not is_admin then
                    return { json = { error = "Access denied - not your store" }, status = 403 }
                end
            end

            -- Get orders for this store with order items
            local orders = db.query([[
                SELECT o.*,
                       c.email as customer_email,
                       c.first_name as customer_first_name,
                       c.last_name as customer_last_name,
                       s.name as store_name
                FROM orders o
                LEFT JOIN customers c ON o.customer_id = c.id
                LEFT JOIN stores s ON o.store_id = s.id
                WHERE s.uuid = ?
                ORDER BY o.created_at DESC
            ]], store_id)

            -- Add order items to each order
            for _, order in ipairs(orders) do
                local items = db.query([[
                    SELECT oi.*, sp.name as current_product_name, sp.uuid as product_uuid
                    FROM orderitems oi
                    LEFT JOIN storeproducts sp ON oi.product_id = sp.id
                    WHERE oi.order_id = ?
                ]], order.id)
                order.items = items

                -- Parse JSON fields
                if order.billing_address then
                    local success, parsed = pcall(require("cjson").decode, order.billing_address)
                    if success then order.billing_address = parsed end
                end
                if order.shipping_address then
                    local success, parsed = pcall(require("cjson").decode, order.shipping_address)
                    if success then order.shipping_address = parsed end
                end
            end

            return { json = orders }
        end)
    }))

    -- Get single order with details (includes delivery partner info)
    app:match("order_details", "/api/v2/orders/:id", respond_to({
        GET = AuthMiddleware.requireAuth(function(self)
            local order_id = self.params.id

            -- Get order with store and delivery partner info
            local orders = db.query([[
                SELECT o.*,
                       c.email as customer_email,
                       c.first_name as customer_first_name,
                       c.last_name as customer_last_name,
                       c.phone as customer_phone,
                       s.name as store_name,
                       s.uuid as store_uuid,
                       s.user_id as store_owner_id,
                       -- Delivery partner fields
                       dp.id as dp_id,
                       dp.uuid as dp_uuid,
                       dp.company_name as dp_company_name,
                       dp.contact_person_name as dp_contact_person_name,
                       dp.contact_person_phone as dp_contact_person_phone,
                       dp.rating as dp_rating,
                       dp.total_deliveries as dp_total_deliveries,
                       dp.service_type as dp_service_type,
                       dp.vehicle_types as dp_vehicle_types,
                       -- Delivery assignment fields
                       oda.id as assignment_id,
                       oda.uuid as assignment_uuid,
                       oda.status as delivery_status,
                       oda.tracking_number as tracking_number,
                       oda.delivery_fee as delivery_fee,
                       oda.accepted_at,
                       oda.actual_pickup_time,
                       oda.estimated_delivery_time,
                       oda.actual_delivery_time
                FROM orders o
                LEFT JOIN customers c ON o.customer_id = c.id
                LEFT JOIN stores s ON o.store_id = s.id
                LEFT JOIN delivery_partners dp ON o.delivery_partner_id = dp.id
                LEFT JOIN order_delivery_assignments oda ON o.id = oda.order_id
                WHERE o.uuid = ?
            ]], order_id)

            if not orders or #orders == 0 then
                return { json = { error = "Order not found" }, status = 404 }
            end

            local order = orders[1]

            -- Check if user owns the store, is the buyer, or is admin
            local user_id_result = db.select("id from users where uuid = ?", self.current_user.uuid)
            if not user_id_result or #user_id_result == 0 then
                return { json = { error = "User not found" }, status = 404 }
            end
            local user_id = user_id_result[1].id

            -- Check if user is buyer (owns customer record)
            local is_buyer = false
            if order.customer_email then
                local user_result = db.query("SELECT email FROM users WHERE id = ?", user_id)
                if user_result and user_result[1] and user_result[1].email == order.customer_email then
                    is_buyer = true
                end
            end

            if order.store_owner_id ~= user_id and not is_buyer then
                -- Check admin access
                local UserQueries = require("queries.UserQueries")
                local user_data = UserQueries.show(self.current_user.uuid)
                local is_admin = false
                if user_data and user_data.roles then
                    for _, role in ipairs(user_data.roles) do
                        if role.name == "admin" then
                            is_admin = true
                            break
                        end
                    end
                end

                if not is_admin then
                    return { json = { error = "Access denied" }, status = 403 }
                end
            end

            -- Get order items
            local items = db.query([[
                SELECT oi.*, sp.name as current_product_name, sp.uuid as product_uuid
                FROM orderitems oi
                LEFT JOIN storeproducts sp ON oi.product_id = sp.id
                WHERE oi.order_id = ?
            ]], order.id)
            order.items = items

            -- Parse JSON fields
            if order.billing_address then
                local success, parsed = pcall(require("cjson").decode, order.billing_address)
                if success then order.billing_address = parsed end
            end
            if order.shipping_address then
                local success, parsed = pcall(require("cjson").decode, order.shipping_address)
                if success then order.shipping_address = parsed end
            end

            -- Structure delivery partner info if available
            if order.dp_id then
                -- Parse vehicle types
                local vehicle_types = {}
                if order.dp_vehicle_types and order.dp_vehicle_types ~= "" then
                    local ok, parsed = pcall(require("cjson").decode, order.dp_vehicle_types)
                    if ok and type(parsed) == "table" then
                        vehicle_types = parsed
                    end
                end

                order.delivery_partner = {
                    id = order.dp_id,
                    uuid = order.dp_uuid,
                    company_name = order.dp_company_name,
                    contact_person_name = order.dp_contact_person_name,
                    contact_person_phone = order.dp_contact_person_phone,
                    rating = tonumber(order.dp_rating) or 0,
                    total_deliveries = tonumber(order.dp_total_deliveries) or 0,
                    service_type = order.dp_service_type,
                    vehicle_types = vehicle_types
                }

                -- Add delivery assignment details
                if order.assignment_id then
                    order.delivery_assignment = {
                        id = order.assignment_id,
                        uuid = order.assignment_uuid,
                        status = order.delivery_status,
                        tracking_number = order.tracking_number,
                        delivery_fee = tonumber(order.delivery_fee) or 0,
                        accepted_at = order.accepted_at,
                        actual_pickup_time = order.actual_pickup_time,
                        estimated_delivery_time = order.estimated_delivery_time,
                        actual_delivery_time = order.actual_delivery_time
                    }
                end

                -- Remove prefixed fields from main order object
                local fields_to_remove = {
                    "dp_id", "dp_uuid", "dp_company_name", "dp_contact_person_name",
                    "dp_contact_person_phone", "dp_rating", "dp_total_deliveries",
                    "dp_service_type", "dp_vehicle_types", "assignment_id", "assignment_uuid",
                    "delivery_status", "tracking_number", "delivery_fee", "accepted_at",
                    "actual_pickup_time", "estimated_delivery_time", "actual_delivery_time"
                }
                for _, field in ipairs(fields_to_remove) do
                    order[field] = nil
                end
            end

            return { json = order }
        end)
    }))

    -- Update order status
    app:match("update_order_status", "/api/v2/orders/:id/status", respond_to({
        PUT = AuthMiddleware.requireAuth(function(self)
            local order_id = self.params.id
            local new_status = self.params.status
            local new_financial_status = self.params.financial_status
            local new_fulfillment_status = self.params.fulfillment_status
            local internal_notes = self.params.internal_notes

            -- Validate status values
            local valid_statuses = {"pending", "processing", "shipped", "delivered", "cancelled"}
            local valid_financial_statuses = {"pending", "paid", "partially_paid", "refunded", "voided"}
            local valid_fulfillment_statuses = {"unfulfilled", "partial", "fulfilled", "cancelled"}

            -- Get order and verify ownership
            local orders = db.query([[
                SELECT o.*, s.user_id as store_owner_id
                FROM orders o
                LEFT JOIN stores s ON o.store_id = s.id
                WHERE o.uuid = ?
            ]], order_id)

            if not orders or #orders == 0 then
                return { json = { error = "Order not found" }, status = 404 }
            end

            local order = orders[1]

            -- Check ownership
            local user_id_result = db.select("id from users where uuid = ?", self.current_user.uuid)
            if not user_id_result or #user_id_result == 0 then
                return { json = { error = "User not found" }, status = 404 }
            end
            local user_id = user_id_result[1].id

            if order.store_owner_id ~= user_id then
                return { json = { error = "Access denied - not your store" }, status = 403 }
            end

            -- Update order
            local update_data = { updated_at = db.format_date() }
            if new_status then update_data.status = new_status end
            if new_financial_status then update_data.financial_status = new_financial_status end
            if new_fulfillment_status then update_data.fulfillment_status = new_fulfillment_status end
            if internal_notes then update_data.internal_notes = internal_notes end

            db.update("orders", update_data, "uuid = ?", order_id)

            return { json = { message = "Order status updated successfully" } }
        end)
    }))

    -- Legacy individual order route
    app:match("edit_order", "/api/v2/orders/:id", respond_to({
        before = function(self)
            self.order = OrderQueries.show(tostring(self.params.id))
            if not self.order then
                self:write({ json = { error = "Order not found!" }, status = 404 })
            end
        end,
        GET = function(self)
            return { json = self.order, status = 200 }
        end,
        PUT = function(self)
            return { json = OrderQueries.update(self.params.id, self.params), status = 204 }
        end,
        DELETE = function(self)
            return { json = OrderQueries.destroy(self.params.id), status = 204 }
        end
    }))
end
