local respond_to = require("lapis.application").respond_to
local OrderQueries = require("queries.OrderQueries")
local OrderitemQueries = require("queries.OrderitemQueries")
local CustomerQueries = require("queries.CustomerQueries")
local AuthMiddleware = require("middleware.auth")
local CartCalculator = require("lib.cart-calculator")
local db = require("lapis.db")
local Global = require("helper.global")

return function(app)
    app:match("checkout", "/api/v2/checkout", respond_to({
        POST = AuthMiddleware.requireAuth(function(self)
            local params = self.params

            -- Get user UUID from authenticated user
            if not self.current_user or not self.current_user.uuid then
                return { json = { error = "Authentication required" }, status = 401 }
            end
            local user_uuid = self.current_user.uuid

            -- Get user's internal ID from database
            local user_result = db.select("id from users where uuid = ?", user_uuid)
            if not user_result or #user_result == 0 then
                return { json = { error = "User not found" }, status = 404 }
            end
            local user_id = user_result[1].id

            -- Get cart items from database
            local cart_items = db.select("* from cart_items where user_id = ?", user_id)

            if not cart_items or #cart_items == 0 then
                return { json = { error = "Cart is empty" }, status = 400 }
            end

            if not params.billing_address or not params.billing_address.name then
                return { json = { error = "Billing address required" }, status = 400 }
            end

            local success, result = pcall(function()
                local customer
                -- Check if customer exists for this user
                local existing_customer = db.select("* from customers where user_id = ?", user_id)

                if existing_customer and #existing_customer > 0 then
                    customer = existing_customer[1]
                else
                    -- Get user details to create customer
                    local user = db.select("* from users where id = ?", user_id)
                    if not user or #user == 0 then
                        error("User not found")
                    end
                    local user_data = user[1]

                    -- Create new customer linked to user
                    local customer_email = params.customer_email or user_data.email
                    local customer_first_name = params.customer_first_name or user_data.first_name
                    local customer_last_name = params.customer_last_name or user_data.last_name
                    local customer_phone = params.customer_phone or user_data.phone_no

                    customer = CustomerQueries.create({
                        email = customer_email,
                        first_name = customer_first_name,
                        last_name = customer_last_name,
                        phone = customer_phone
                    })

                    -- Link customer to user
                    if customer and customer.id then
                        db.update("customers", { user_id = user_id }, "id = ?", customer.id)
                    end
                end

                local store_orders = {}
                local StoreproductQueries = require("queries.StoreproductQueries")

                -- Group cart items by store
                for _, item in ipairs(cart_items) do
                    local product = StoreproductQueries.show(item.product_uuid)
                    if not product then
                        error("Product not found: " .. item.product_uuid)
                    end

                    local store_id = product.store_id
                    if not store_orders[store_id] then
                        store_orders[store_id] = { items = {}, subtotal = 0 }
                    end

                    local item_total = tonumber(item.price) * tonumber(item.quantity)
                    table.insert(store_orders[store_id].items, {
                        product = product,
                        quantity = tonumber(item.quantity),
                        price = tonumber(item.price),
                        total = item_total,
                        variant_uuid = item.variant_uuid,
                        variant_title = item.variant_title
                    })

                    store_orders[store_id].subtotal = store_orders[store_id].subtotal + item_total
                end

                -- Calculate totals using CartCalculator for accurate tax/shipping
                local cart_totals = CartCalculator.calculateCheckoutTotals(user_id)

                local orders = {}
                local order_numbers = {}

                for store_id, store_order in pairs(store_orders) do
                    -- Generate unique order number
                    local order_number = "ORD-" .. os.date("%Y%m%d") .. "-" .. string.upper(string.sub(Global.generateUUID(), 1, 8))

                    -- Calculate store-specific totals (proportional)
                    local store_subtotal = store_order.subtotal
                    local store_tax = (cart_totals.tax_amount or 0) * (store_subtotal / cart_totals.subtotal)
                    local store_shipping = (cart_totals.shipping_amount or 0) * (store_subtotal / cart_totals.subtotal)
                    local store_total = store_subtotal + store_tax + store_shipping

                    local order_data = {
                        uuid = Global.generateUUID(),
                        store_id = store_id,
                        customer_id = customer and customer.id or nil,
                        order_number = order_number,
                        status = "pending",
                        financial_status = "pending",
                        fulfillment_status = "unfulfilled",
                        subtotal = store_subtotal,
                        tax_amount = store_tax,
                        shipping_amount = store_shipping,
                        total_amount = store_total,
                        currency = "USD",
                        billing_address = require("cjson").encode(params.billing_address),
                        shipping_address = require("cjson").encode(params.shipping_address or params.billing_address),
                        customer_notes = params.customer_notes,
                        processed_at = db.format_date(),
                        created_at = db.format_date(),
                        updated_at = db.format_date()
                    }

                    local order = OrderQueries.create(order_data)

                    -- Create order items
                    for _, item in ipairs(store_order.items) do
                        OrderitemQueries.create({
                            uuid = Global.generateUUID(),
                            order_id = order.id,
                            product_id = item.product.id,
                            variant_id = item.variant_uuid,
                            quantity = item.quantity,
                            price = item.price,
                            total = item.total,
                            product_title = item.product.name,
                            variant_title = item.variant_title,
                            sku = item.product.sku,
                            created_at = db.format_date(),
                            updated_at = db.format_date()
                        })
                    end

                    -- Add order number for reference
                    order.order_number = order_number
                    table.insert(orders, order)
                    table.insert(order_numbers, order_number)
                end

                -- Clear cart after successful checkout
                db.delete("cart_items", "user_id = ?", user_id)

                return {
                    orders = orders,
                    order_numbers = order_numbers,
                    total_amount = cart_totals.total_amount,
                    message = "Checkout successful"
                }
            end)

            if not success then
                return { json = { error = result }, status = 400 }
            end

            return { json = result, status = 201 }
        end)
    }))
end