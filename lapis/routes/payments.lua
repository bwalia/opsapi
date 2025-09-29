local respond_to = require("lapis.application").respond_to
local Stripe = require("lib.stripe")
local OrderQueries = require("queries.OrderQueries")
local AuthMiddleware = require("middleware.auth")
local CartCalculator = require("lib.cart-calculator")
local Global = require("helper.global")
local cjson = require("cjson")

return function(app)
    -- Test Stripe Connection
    app:match("test_stripe", "/api/v2/payments/test", respond_to({
        GET = function(self)
            local success, result = pcall(function()
                local stripe = Stripe.new()

                return {
                    status = "success",
                    message = "Stripe client initialized successfully"
                }
            end)

            if not success then
                ngx.log(ngx.ERR, "Stripe test failed: " .. tostring(result))
                return { json = { error = "Stripe test failed", details = tostring(result) }, status = 500 }
            end

            return { json = result, status = 200 }
        end
    }))

    -- Test Checkout Session Creation
    app:match("test_checkout_session", "/api/v2/payments/test-checkout", respond_to({
        GET = function(self)
            local success, result = pcall(function()
                local stripe = Stripe.new()

                -- Create a simple test checkout session
                local session, err = stripe:create_checkout_session({
                    mode = "payment",
                    line_items = {
                        {
                            price_data = {
                                currency = "usd",
                                product_data = {
                                    name = "Test Product"
                                },
                                unit_amount = 1000 -- $10.00
                            },
                            quantity = 1
                        }
                    },
                    success_url = "http://localhost:3000/payment/success?session_id={CHECKOUT_SESSION_ID}",
                    cancel_url = "http://localhost:3000/checkout"
                })

                if not session then
                    error("Failed to create test checkout session: " .. (err or "unknown error"))
                end

                return {
                    status = "success",
                    session_id = session.id,
                    url = session.url
                }
            end)

            if not success then
                ngx.log(ngx.ERR, "Test checkout session failed: " .. tostring(result))
                return { json = { error = "Test checkout session failed", details = tostring(result) }, status = 500 }
            end

            return { json = result, status = 200 }
        end
    }))

    -- Create Stripe Checkout Session (Hosted Checkout)
    app:match("create_checkout_session", "/api/v2/payments/create-checkout-session", respond_to({
        POST = AuthMiddleware.requireAuth(function(self)
            local params = self.params

            -- Validate cart and get items
            local user_uuid = ngx.var.http_x_user_id
            if not user_uuid or user_uuid == "" then
                return { json = { error = "Authentication required" }, status = 401 }
            end

            local db = require("lapis.db")
            local user_result = db.select("id from users where uuid = ?", user_uuid)
            if not user_result or #user_result == 0 then
                return { json = { error = "User not found" }, status = 404 }
            end
            local user_id = user_result[1].id

            local cart_items = db.select("* from cart_items where user_id = ?", user_id)
            if not cart_items or #cart_items == 0 then
                return { json = { error = "Cart is empty" }, status = 400 }
            end

            local success, result = pcall(function()
                local stripe = Stripe.new()

                -- Calculate totals using the new cart calculator
                local totals = CartCalculator.calculateCheckoutTotals(user_id)

                if totals.total_amount == 0 then
                    error("Cart total is zero")
                end

                -- Build line items for Stripe Checkout
                local line_items = {}

                ngx.log(ngx.INFO, "Building line items for " .. #cart_items .. " cart items")

                -- Add product line items
                for _, item in ipairs(cart_items) do
                    local item_price = tonumber(item.price)
                    local item_quantity = tonumber(item.quantity)

                    if not item_price or not item_quantity then
                        error("Invalid cart item: price=" .. tostring(item.price) .. ", quantity=" .. tostring(item.quantity))
                    end

                    ngx.log(ngx.INFO, "Adding line item: " .. item.name .. " - $" .. item_price .. " x " .. item_quantity)

                    -- Build product data with conditional description
                    local product_data = {
                        name = item.name or "Unknown Product"
                    }

                    -- Only add description if variant_title exists and is not empty
                    if item.variant_title and item.variant_title ~= "" then
                        product_data.description = item.variant_title
                    end

                    -- Add line item
                    table.insert(line_items, {
                        price_data = {
                            currency = "usd",
                            product_data = product_data,
                            unit_amount = math.floor(item_price * 100) -- Convert to cents
                        },
                        quantity = item_quantity
                    })
                end

                -- Add tax as a separate line item if applicable
                if totals.tax_amount > 0 then
                    ngx.log(ngx.INFO, "Adding tax line item: $" .. totals.tax_amount)

                    table.insert(line_items, {
                        price_data = {
                            currency = "usd",
                            product_data = {
                                name = "Tax"
                            },
                            unit_amount = math.floor(totals.tax_amount * 100)
                        },
                        quantity = 1
                    })
                end

                -- Add shipping as a separate line item if applicable
                if totals.shipping_amount > 0 then
                    ngx.log(ngx.INFO, "Adding shipping line item: $" .. totals.shipping_amount)

                    table.insert(line_items, {
                        price_data = {
                            currency = "usd",
                            product_data = {
                                name = "Shipping"
                            },
                            unit_amount = math.floor(totals.shipping_amount * 100)
                        },
                        quantity = 1
                    })
                end

                ngx.log(ngx.INFO, "Total line items: " .. #line_items)

                -- Create checkout session
                local session, err = stripe:create_checkout_session({
                    mode = "payment",
                    line_items = line_items,
                    success_url = params.success_url or "http://localhost:3000/payment/success?session_id={CHECKOUT_SESSION_ID}",
                    cancel_url = params.cancel_url or "http://localhost:3000/checkout",
                    customer_email = params.customer_email,
                    billing_address_collection = "required",
                    metadata = {
                        user_id = tostring(user_id),
                        subtotal = tostring(totals.subtotal),
                        tax_amount = tostring(totals.tax_amount),
                        shipping_amount = tostring(totals.shipping_amount),
                        total_amount = tostring(totals.total_amount)
                    }
                })

                if not session then
                    ngx.log(ngx.ERR, "Stripe create_checkout_session failed: " .. (err or "unknown error"))
                    error("Failed to create checkout session: " .. (err or "unknown error"))
                end

                ngx.log(ngx.INFO, "Checkout session created successfully: " .. session.id)

                return {
                    session_id = session.id,
                    url = session.url
                }
            end)

            if not success then
                ngx.log(ngx.ERR, "Checkout session creation failed: " .. tostring(result))
                return { json = { error = "Checkout session creation failed", details = tostring(result) }, status = 500 }
            end

            return { json = result, status = 200 }
        end)
    }))

    -- Create Payment Intent (Modern Stripe approach)
    app:match("create_payment_intent", "/api/v2/payments/create-intent", respond_to({
        POST = AuthMiddleware.requireAuth(function(self)
            local params = self.params

            -- Validate required parameters
            if not params.amount or tonumber(params.amount) <= 0 then
                return { json = { error = "Valid amount is required" }, status = 400 }
            end

            local amount = tonumber(params.amount)
            local currency = params.currency or "usd"

            -- Validate cart and calculate total
            local user_uuid = ngx.var.http_x_user_id
            if not user_uuid or user_uuid == "" then
                return { json = { error = "Authentication required" }, status = 401 }
            end

            local db = require("lapis.db")
            local user_result = db.select("id from users where uuid = ?", user_uuid)
            if not user_result or #user_result == 0 then
                return { json = { error = "User not found" }, status = 404 }
            end
            local user_id = user_result[1].id

            local cart_items = db.select("* from cart_items where user_id = ?", user_id)
            if not cart_items or #cart_items == 0 then
                return { json = { error = "Cart is empty" }, status = 400 }
            end

            -- Calculate total using STORED cart prices (same as cart API)
            local calculated_total = 0

            for _, item in ipairs(cart_items) do
                -- Use the price stored in cart_items (when item was added)
                local item_price = tonumber(item.price)
                local item_quantity = tonumber(item.quantity)
                if not item_price or not item_quantity then
                    return { json = { error = "Invalid cart item data" }, status = 400 }
                end
                calculated_total = calculated_total + (item_price * item_quantity)
            end

            local tax_amount = calculated_total * 0.1
            local final_total = calculated_total + tax_amount

            if math.abs(amount - final_total) > 0.01 then
                return { json = { error = "Amount mismatch. Expected: " .. final_total }, status = 400 }
            end

            local success, result = pcall(function()
                local stripe = Stripe.new()

                -- Create payment intent with idempotency
                local payment_intent, err = stripe:create_payment_intent(amount, currency, {
                    description = "Order payment for " .. tostring(#cart_items) .. " items",
                    receipt_email = params.customer_email,
                    metadata = {
                        user_id = tostring(user_id),
                        cart_total = tostring(calculated_total),
                        tax_amount = tostring(tax_amount),
                        cart_hash = tostring(user_id) .. "_" .. tostring(final_total) .. "_" .. tostring(#cart_items)
                    }
                })

                if not payment_intent then
                    error("Failed to create payment intent: " .. (err or "unknown error"))
                end

                return {
                    client_secret = payment_intent.client_secret,
                    payment_intent_id = payment_intent.id,
                    amount = payment_intent.amount,
                    currency = payment_intent.currency
                }
            end)

            if not success then
                ngx.log(ngx.ERR, "Payment intent creation failed: " .. tostring(result))
                return { json = { error = "Payment intent creation failed", details = tostring(result) }, status = 500 }
            end

            return { json = result, status = 200 }
        end)
    }))
    
    -- Confirm Payment and Complete Order
    app:match("confirm_payment", "/api/v2/payments/confirm", respond_to({
        POST = AuthMiddleware.requireAuth(function(self)
            local params = self.params

            if not params.payment_intent_id and not params.session_id then
                return { json = { error = "Payment intent ID or session ID is required" }, status = 400 }
            end

            local success, result = pcall(function()
                local stripe = Stripe.new()
                local payment_reference_id = nil

                if params.session_id then
                    -- Handle Stripe Checkout Session
                    local session, err = stripe:retrieve_checkout_session(params.session_id)

                    if not session then
                        error("Failed to retrieve checkout session: " .. (err or "unknown error"))
                    end

                    if session.payment_status ~= "paid" then
                        error("Payment not completed. Session status: " .. (session.payment_status or "unknown"))
                    end

                    payment_reference_id = session.id
                else
                    -- Handle Payment Intent (legacy support)
                    local payment_intent, err = stripe:retrieve_payment_intent(params.payment_intent_id)

                    if not payment_intent then
                        error("Failed to retrieve payment intent: " .. (err or "unknown error"))
                    end

                    if payment_intent.status ~= "succeeded" then
                        error("Payment not completed. Status: " .. payment_intent.status)
                    end

                    payment_reference_id = payment_intent.id
                end
                
                -- Get cart and create order
                local user_uuid = ngx.var.http_x_user_id
                if not user_uuid or user_uuid == "" then
                    error("Authentication required")
                end
                
                -- Get user's internal ID from database
                local db = require("lapis.db")
                local user_result = db.select("id from users where uuid = ?", user_uuid)
                if not user_result or #user_result == 0 then
                    error("User not found")
                end
                local user_id = user_result[1].id
                
                -- Get cart items from database
                local cart_items = db.select("* from cart_items where user_id = ?", user_id)
                if not cart_items or #cart_items == 0 then
                    error("Cart is empty")
                end
                
                -- Convert to cart format with stored prices
                local cart = {}
                for _, item in ipairs(cart_items) do
                    cart[item.product_uuid] = {
                        quantity = tonumber(item.quantity),
                        variant_uuid = item.variant_uuid,
                        stored_price = tonumber(item.price)  -- Use stored price from cart
                    }
                end
                
                -- Create order with payment information
                local OrderQueries = require("queries.OrderQueries")
                local OrderitemQueries = require("queries.OrderitemQueries")
                local CustomerQueries = require("queries.CustomerQueries")
                local StoreproductQueries = require("queries.StoreproductQueries")
                
                -- Create customer if provided
                local customer = nil
                if params.customer_email then
                    customer = CustomerQueries.create({
                        email = params.customer_email,
                        first_name = params.customer_first_name,
                        last_name = params.customer_last_name,
                        phone = params.customer_phone
                    })
                end
                
                -- Group items by store
                local store_orders = {}
                local subtotal = 0
                
                for product_uuid, item in pairs(cart) do
                    local product = StoreproductQueries.show(product_uuid)
                    if not product then
                        error("Product not found: " .. product_uuid)
                    end

                    local store_id = product.store_id
                    if not store_orders[store_id] then
                        store_orders[store_id] = { items = {}, subtotal = 0 }
                    end

                    -- Use stored cart price instead of current product price
                    local item_price = item.stored_price
                    if not item_price then
                        error("Cart item missing stored price for product: " .. product_uuid)
                    end
                    
                    local item_total = item_price * item.quantity
                    table.insert(store_orders[store_id].items, {
                        product = product,
                        quantity = item.quantity,
                        price = item_price,
                        total = item_total,
                        variant_uuid = item.variant_uuid
                    })
                    
                    store_orders[store_id].subtotal = store_orders[store_id].subtotal + item_total
                    subtotal = subtotal + item_total
                end
                
                local tax_amount = subtotal * 0.1
                local total_amount = subtotal + tax_amount
                
                -- Create orders for each store
                local orders = {}
                for store_id, store_order in pairs(store_orders) do
                    -- Serialize address data as JSON string if it's a table
                    local billing_address_str = params.billing_address
                    if type(params.billing_address) == "table" then
                        billing_address_str = cjson.encode(params.billing_address)
                    end

                    local shipping_address_str = params.shipping_address or params.billing_address
                    if type(shipping_address_str) == "table" then
                        shipping_address_str = cjson.encode(shipping_address_str)
                    end

                    local order = OrderQueries.create({
                        store_id = store_id,
                        customer_id = customer and customer.id or nil,
                        subtotal = store_order.subtotal,
                        tax_amount = tax_amount * (store_order.subtotal / subtotal),
                        total_amount = store_order.subtotal + (tax_amount * (store_order.subtotal / subtotal)),
                        billing_address = billing_address_str,
                        shipping_address = shipping_address_str,
                        payment_intent_id = payment_reference_id,
                        payment_status = "paid",
                        payment_method = "stripe"
                    })
                    
                    -- Create order items
                    for _, item in ipairs(store_order.items) do
                        OrderitemQueries.create({
                            order_id = order.id,
                            product_id = item.product.uuid,  -- Use UUID for product lookup
                            variant_uuid = item.variant_uuid, -- Use correct field name
                            quantity = item.quantity,
                            price = item.price,
                            total = item.total,
                            product_title = item.product.name,
                            sku = item.product.sku
                        })
                    end
                    
                    table.insert(orders, order)
                end
                
                -- Clear cart after successful order
                db.delete("cart_items", "user_id = ?", user_id)
                
                return {
                    orders = orders,
                    payment_intent_id = payment_reference_id,
                    total_amount = total_amount,
                    message = "Order completed successfully"
                }
            end)
            
            if not success then
                ngx.log(ngx.ERR, "Payment confirmation failed: " .. tostring(result))
                return { json = { error = "Order processing failed", details = tostring(result) }, status = 500 }
            end
            
            return { json = result, status = 201 }
        end)
    }))
end