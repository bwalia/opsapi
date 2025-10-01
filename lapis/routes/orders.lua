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
            local orders = db.select([[
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
                local items = db.select([[
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

    -- Get single order with details
    app:match("order_details", "/api/v2/orders/:id", respond_to({
        GET = AuthMiddleware.requireAuth(function(self)
            local order_id = self.params.id

            -- Get order with store info
            local orders = db.select([[
                SELECT o.*,
                       c.email as customer_email,
                       c.first_name as customer_first_name,
                       c.last_name as customer_last_name,
                       c.phone as customer_phone,
                       s.name as store_name,
                       s.uuid as store_uuid,
                       s.user_id as store_owner_id
                FROM orders o
                LEFT JOIN customers c ON o.customer_id = c.id
                LEFT JOIN stores s ON o.store_id = s.id
                WHERE o.uuid = ?
            ]], order_id)

            if not orders or #orders == 0 then
                return { json = { error = "Order not found" }, status = 404 }
            end

            local order = orders[1]

            -- Check if user owns the store or is admin
            local user_id_result = db.select("id from users where uuid = ?", self.current_user.uuid)
            if not user_id_result or #user_id_result == 0 then
                return { json = { error = "User not found" }, status = 404 }
            end
            local user_id = user_id_result[1].id

            if order.store_owner_id ~= user_id then
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
            local items = db.select([[
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
            local orders = db.select([[
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
