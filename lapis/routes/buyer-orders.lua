local respond_to = require("lapis.application").respond_to
local AuthMiddleware = require("middleware.auth")
local db = require("lapis.db")
local cjson = require("cjson")
local NotificationHelper = require("helper.notification-helper")

return function(app)
    -- Get buyer's own orders
    app:match("buyer_orders", "/api/v2/buyer/orders", respond_to({
        GET = AuthMiddleware.requireAuth(function(self)
            ngx.log(ngx.INFO, "=== BUYER ORDERS ROUTE CALLED ===")
            ngx.log(ngx.INFO, "Fetching orders for user: " .. tostring(self.current_user.uuid))
            local success, result = pcall(function()
                local user_id_result = db.select("id from users where uuid = ?", self.current_user.uuid)
                if not user_id_result or #user_id_result == 0 then
                    return { json = { error = "User not found" }, status = 404 }
                end
                local user_id = user_id_result[1].id

                -- Get user's customer record
                local customer = db.select("* from customers where user_id = ?", user_id)
                if not customer or #customer == 0 then
                    return { json = {} }
                end
                local customer_id = customer[1].id

                -- Get all orders with store and payment info
                local orders = db.query([[
                    SELECT o.*,
                           s.name as store_name,
                           s.uuid as store_uuid,
                           s.slug as store_slug,
                           p.stripe_payment_intent_id,
                           p.card_brand,
                           p.card_last4,
                           p.receipt_url
                    FROM orders o
                    LEFT JOIN stores s ON o.store_id = s.id
                    LEFT JOIN payments p ON o.payment_id = p.id
                    WHERE o.customer_id = ?
                    ORDER BY o.created_at DESC
                ]], customer_id)

                -- Add items and status history to each order
                for _, order in ipairs(orders) do
                    ngx.log(ngx.INFO, "Processing order ID: " .. tostring(order.id))
                    -- Get order items with product info
                    local items = db.query([[
                        SELECT oi.*,
                               sp.name as product_name,
                               sp.uuid as product_uuid,
                               sp.images as product_images
                        FROM orderitems oi
                        LEFT JOIN storeproducts sp ON oi.product_id = sp.id
                        WHERE oi.order_id = ?
                    ]], order.id)

                    -- Ensure items is an array
                    if not items then
                        items = {}
                    end

                    -- Parse images JSON and extract first image
                    for _, item in ipairs(items) do
                        if item.product_images then
                            local parse_success, parsed = pcall(cjson.decode, item.product_images)
                            if parse_success and parsed and #parsed > 0 then
                                item.product_image = parsed[1]
                            end
                            item.product_images = nil -- Remove raw JSON
                        end
                    end

                    order.items = items or {}

                    -- Get status history
                    local status_history = db.query([[
                        SELECT osh.*,
                               u.first_name || ' ' || u.last_name as changed_by_name
                        FROM order_status_history osh
                        LEFT JOIN users u ON osh.changed_by_user_id = u.id
                        WHERE osh.order_id = ?
                        ORDER BY osh.created_at ASC
                    ]], order.id)
                    order.status_history = status_history

                    -- Parse JSON fields
                    if order.billing_address then
                        local parse_success, parsed = pcall(cjson.decode, order.billing_address)
                        if parse_success then order.billing_address = parsed end
                    end
                    if order.shipping_address then
                        local parse_success, parsed = pcall(cjson.decode, order.shipping_address)
                        if parse_success then order.shipping_address = parsed end
                    end
                end

                return { json = orders }
            end)

            if not success then
                ngx.log(ngx.ERR, "Error in buyer_orders: " .. tostring(result))
                return { json = { error = "Internal server error" }, status = 500 }
            end

            return result
        end)
    }))

    -- Get single order details for buyer
    app:match("buyer_order_details", "/api/v2/buyer/orders/:order_id", respond_to({
        GET = AuthMiddleware.requireAuth(function(self)
            local success, result = pcall(function()
                local order_uuid = self.params.order_id

                -- Get user's customer ID
                local user_id_result = db.select("id from users where uuid = ?", self.current_user.uuid)
                if not user_id_result or #user_id_result == 0 then
                    return { json = { error = "User not found" }, status = 404 }
                end
                local user_id = user_id_result[1].id

                local customer = db.select("* from customers where user_id = ?", user_id)
                if not customer or #customer == 0 then
                    return { json = { error = "Customer record not found" }, status = 404 }
                end
                local customer_id = customer[1].id

                -- Get order with full details
                local orders = db.query([[
                    SELECT o.*,
                           s.name as store_name,
                           s.uuid as store_uuid,
                           s.slug as store_slug,
                           s.contact_email as store_email,
                           s.contact_phone as store_phone,
                           p.stripe_payment_intent_id,
                           p.card_brand,
                           p.card_last4,
                           p.amount as payment_amount,
                           p.receipt_url,
                           p.created_at as payment_date
                    FROM orders o
                    LEFT JOIN stores s ON o.store_id = s.id
                    LEFT JOIN payments p ON o.payment_id = p.id
                    WHERE o.uuid = ? AND o.customer_id = ?
                ]], order_uuid, customer_id)

                if not orders or #orders == 0 then
                    return { json = { error = "Order not found" }, status = 404 }
                end

                local order = orders[1]

                -- Get order items with product details
                local items = db.query([[
                    SELECT oi.*,
                           sp.name as product_name,
                           sp.uuid as product_uuid,
                           sp.description as product_description,
                           sp.images as product_image,
                           sp.price as current_price,
                           sp.inventory_quantity as current_stock
                    FROM orderitems oi
                    LEFT JOIN storeproducts sp ON oi.product_id = sp.id
                    WHERE oi.order_id = ?
                ]], order.id)
                order.items = items

                -- Get status history with timeline
                local status_history = db.query([[
                    SELECT osh.*,
                           u.first_name || ' ' || u.last_name as changed_by_name
                    FROM order_status_history osh
                    LEFT JOIN users u ON osh.changed_by_user_id = u.id
                    WHERE osh.order_id = ?
                    ORDER BY osh.created_at ASC
                ]], order.id)
                order.status_history = status_history

                -- Parse JSON fields
                if order.billing_address then
                    local parse_success, parsed = pcall(cjson.decode, order.billing_address)
                    if parse_success then order.billing_address = parsed end
                end
                if order.shipping_address then
                    local parse_success, parsed = pcall(cjson.decode, order.shipping_address)
                    if parse_success then order.shipping_address = parsed end
                end

                return { json = order }
            end)

            if not success then
                ngx.log(ngx.ERR, "Error in buyer_order_details: " .. tostring(result))
                return { json = { error = "Internal server error" }, status = 500 }
            end

            return result
        end)
    }))

    -- Repeat order (create new order from existing one)
    app:match("repeat_order", "/api/v2/buyer/orders/:order_id/repeat", respond_to({
        POST = AuthMiddleware.requireAuth(function(self)
            local success, result = pcall(function()
                local order_uuid = self.params.order_id

                -- Get user's customer ID
                local user_id_result = db.select("id from users where uuid = ?", self.current_user.uuid)
                if not user_id_result or #user_id_result == 0 then
                    return { json = { error = "User not found" }, status = 404 }
                end
                local user_id = user_id_result[1].id

                local customer = db.select("* from customers where user_id = ?", user_id)
                if not customer or #customer == 0 then
                    return { json = { error = "Customer record not found" }, status = 404 }
                end
                local customer_id = customer[1].id

                -- Get original order
                local orders = db.query([[
                    SELECT * FROM orders WHERE uuid = ? AND customer_id = ?
                ]], order_uuid, customer_id)

                if not orders or #orders == 0 then
                    return { json = { error = "Order not found" }, status = 404 }
                end

                local original_order = orders[1]

                -- Get original order items
                local items = db.query([[
                    SELECT oi.*, sp.stock as current_stock, sp.price as current_price
                    FROM orderitems oi
                    LEFT JOIN storeproducts sp ON oi.product_id = sp.id
                    WHERE oi.order_id = ?
                ]], original_order.id)

                -- Check product availability
                local unavailable_items = {}
                local available_items = {}

                for _, item in ipairs(items) do
                    if not item.current_stock or item.current_stock < item.quantity then
                        table.insert(unavailable_items, {
                            product_id = item.product_id,
                            name = item.name,
                            requested_quantity = item.quantity,
                            available_stock = item.current_stock or 0
                        })
                    else
                        table.insert(available_items, item)
                    end
                end

                if #unavailable_items > 0 then
                    return {
                        json = {
                            error = "Some products are not available",
                            unavailable_items = unavailable_items
                        },
                        status = 400
                    }
                end

                -- Add items to cart instead of creating order directly
                for _, item in ipairs(available_items) do
                    -- Check if item already in cart
                    local existing = db.query([[
                        SELECT * FROM cart WHERE customer_id = ? AND product_id = ?
                    ]], customer_id, item.product_id)

                    if existing and #existing > 0 then
                        -- Update quantity
                        db.update("cart", {
                            quantity = existing[1].quantity + item.quantity,
                            updated_at = db.format_date()
                        }, "id = ?", existing[1].id)
                    else
                        -- Insert new cart item
                        db.insert("cart", {
                            customer_id = customer_id,
                            product_id = item.product_id,
                            quantity = item.quantity,
                            created_at = db.format_date(),
                            updated_at = db.format_date()
                        })
                    end
                end

                return {
                    json = {
                        message = "Order items added to cart",
                        items_added = #available_items
                    },
                    status = 200
                }
            end)

            if not success then
                ngx.log(ngx.ERR, "Error in repeat_order: " .. tostring(result))
                return { json = { error = "Internal server error" }, status = 500 }
            end

            return result
        end)
    }))

    -- Cancel order (buyer can only cancel pending orders)
    app:match("buyer_cancel_order", "/api/v2/buyer/orders/:order_id/cancel", respond_to({
        POST = AuthMiddleware.requireAuth(function(self)
            local success, result = pcall(function()
                local order_uuid = self.params.order_id
                local reason = self.params.reason

                -- Get user's customer ID
                local user_id_result = db.select("id from users where uuid = ?", self.current_user.uuid)
                if not user_id_result or #user_id_result == 0 then
                    return { json = { error = "User not found" }, status = 404 }
                end
                local user_id = user_id_result[1].id

                local customer = db.select("* from customers where user_id = ?", user_id)
                if not customer or #customer == 0 then
                    return { json = { error = "Customer record not found" }, status = 404 }
                end
                local customer_id = customer[1].id

                -- Get order
                local orders = db.query([[
                    SELECT * FROM orders WHERE uuid = ? AND customer_id = ?
                ]], order_uuid, customer_id)

                if not orders or #orders == 0 then
                    return { json = { error = "Order not found" }, status = 404 }
                end

                local order = orders[1]

                -- Only allow cancellation of pending orders
                if order.status ~= 'pending' then
                    return {
                        json = {
                            error = "Can only cancel pending orders",
                            current_status = order.status
                        },
                        status = 400
                    }
                end

                -- Update order status
                db.update("orders", {
                    status = 'cancelled',
                    updated_at = db.format_date()
                }, "id = ?", order.id)

                -- Create status history entry
                db.insert("order_status_history", {
                    order_id = order.id,
                    old_status = order.status,
                    new_status = 'cancelled',
                    changed_by_user_id = user_id,
                    notes = reason or "Cancelled by customer",
                    created_at = db.format_date()
                })

                -- Send notification to seller
                pcall(function()
                    NotificationHelper.notifySellerOrderCancelled(order.id)
                end)

                return {
                    json = {
                        message = "Order cancelled successfully"
                    },
                    status = 200
                }
            end)

            if not success then
                ngx.log(ngx.ERR, "Error in buyer_cancel_order: " .. tostring(result))
                return { json = { error = "Internal server error" }, status = 500 }
            end

            return result
        end)
    }))
end
