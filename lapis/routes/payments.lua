local respond_to = require("lapis.application").respond_to
local Stripe = require("lib.stripe")
local OrderQueries = require("queries.OrderQueries")
local AuthMiddleware = require("middleware.auth")
local CartCalculator = require("lib.cart-calculator")
local Global = require("helper.global")
local Geocoding = require("lib.Geocoding")
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

    -- Create Stripe Checkout Session (Hosted Checkout)
    app:match("create_checkout_session", "/api/v2/payments/create-checkout-session", respond_to({
        POST = AuthMiddleware.requireAuth(function(self)
            -- Parse JSON body first, fallback to form params
            local params = parse_json_body()
            if not params or not next(params) then
                params = self.params
            end

            -- Get user UUID from authenticated user
            local user_uuid = self.current_user and (self.current_user.uuid or self.current_user.sub)
            if not user_uuid or user_uuid == "" then
                ngx.log(ngx.ERR, "Authentication required - no user UUID found in token")
                return { json = { error = "Authentication required" }, status = 401 }
            end

            ngx.log(ngx.INFO, "Creating checkout session for user: " .. user_uuid)

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

                -- Get or create customer
                local CustomerQueries = require("queries.CustomerQueries")
                local user = db.select("* from users where id = ?", user_id)
                if not user or #user == 0 then
                    error("User not found")
                end
                local user_data = user[1]

                local customer
                local stripe_customer_id = nil

                -- Check if customer exists for this user
                local existing_customer = db.select("* from customers where user_id = ?", user_id)

                if existing_customer and #existing_customer > 0 then
                    customer = existing_customer[1]
                    stripe_customer_id = customer.stripe_customer_id
                else
                    -- Create new customer linked to user
                    local customer_email = params.customer_email or user_data.email
                    local customer_first_name = params.customer_first_name or user_data.first_name
                    local customer_last_name = params.customer_last_name or user_data.last_name
                    local customer_phone = params.customer_phone or user_data.phone_no

                    customer = CustomerQueries.create({
                        email = customer_email,
                        first_name = customer_first_name,
                        last_name = customer_last_name,
                        phone = customer_phone,
                        user_id = user_id
                    })
                end

                -- Create Stripe customer if not exists
                if not stripe_customer_id then
                    local customer_name = (customer.first_name or "") .. " " .. (customer.last_name or "")
                    customer_name = customer_name:match("^%s*(.-)%s*$") -- trim

                    local stripe_customer, err = stripe:create_customer(
                        customer.email,
                        customer_name ~= "" and customer_name or nil,
                        {
                            phone = customer.phone,
                            metadata = {
                                customer_id = tostring(customer.id),
                                user_id = tostring(user_id)
                            }
                        }
                    )

                    if stripe_customer and stripe_customer.id then
                        stripe_customer_id = stripe_customer.id
                        -- Update customer with Stripe ID
                        db.update("customers", { stripe_customer_id = stripe_customer_id }, "id = ?", customer.id)
                    else
                        ngx.log(ngx.WARN, "Failed to create Stripe customer: " .. tostring(err))
                    end
                end

                -- Debug: Log what we're receiving for billing_address
                ngx.log(ngx.INFO, "params.billing_address type: " .. type(params.billing_address))
                ngx.log(ngx.INFO, "params.billing_address value: " .. tostring(params.billing_address))
                if type(params.billing_address) == "table" then
                    ngx.log(ngx.INFO, "params.billing_address (JSON): " .. cjson.encode(params.billing_address))
                end

                -- Ensure billing_address is properly encoded
                local billing_addr_json = "{}"
                local shipping_addr_json = "{}"

                if params.billing_address then
                    if type(params.billing_address) == "table" then
                        billing_addr_json = cjson.encode(params.billing_address)
                    elseif type(params.billing_address) == "string" then
                        -- Validate it's not "[object Object]"
                        if params.billing_address ~= "[object Object]" then
                            billing_addr_json = params.billing_address
                        else
                            ngx.log(ngx.ERR, "Received '[object Object]' for billing_address in checkout session")
                            billing_addr_json = "{}"
                        end
                    end
                end

                if params.shipping_address then
                    if type(params.shipping_address) == "table" then
                        shipping_addr_json = cjson.encode(params.shipping_address)
                    elseif type(params.shipping_address) == "string" then
                        if params.shipping_address ~= "[object Object]" then
                            shipping_addr_json = params.shipping_address
                        else
                            shipping_addr_json = billing_addr_json
                        end
                    end
                else
                    shipping_addr_json = billing_addr_json
                end

                ngx.log(ngx.INFO, "Storing in Stripe metadata - billing_address: " .. billing_addr_json)
                ngx.log(ngx.INFO, "Storing in Stripe metadata - shipping_address: " .. shipping_addr_json)

                -- Create checkout session
                local session, err = stripe:create_checkout_session({
                    mode = "payment",
                    line_items = line_items,
                    success_url = params.success_url or "http://localhost:3000/payment/success?session_id={CHECKOUT_SESSION_ID}",
                    cancel_url = params.cancel_url or "http://localhost:3000/checkout",
                    customer = stripe_customer_id,  -- Use Stripe customer ID
                    customer_email = not stripe_customer_id and params.customer_email or nil,  -- Only if no customer
                    billing_address_collection = "required",
                    metadata = {
                        user_id = tostring(user_id),
                        customer_id = tostring(customer.id),
                        subtotal = tostring(totals.subtotal),
                        tax_amount = tostring(totals.tax_amount),
                        shipping_amount = tostring(totals.shipping_amount),
                        total_amount = tostring(totals.total_amount),
                        billing_address = billing_addr_json,
                        shipping_address = shipping_addr_json,
                        customer_notes = params.customer_notes or ""
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

            -- Get user UUID from authenticated user
            local user_uuid = self.current_user and (self.current_user.uuid or self.current_user.sub)
            if not user_uuid or user_uuid == "" then
                ngx.log(ngx.ERR, "Authentication required - no user UUID found in token")
                return { json = { error = "Authentication required" }, status = 401 }
            end

            ngx.log(ngx.INFO, "Creating payment intent for user: " .. user_uuid)

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
            -- Parse JSON body first, fallback to form params
            local params = parse_json_body()
            if not params or not next(params) then
                params = self.params
            end

            if not params.payment_intent_id and not params.session_id then
                return { json = { error = "Payment intent ID or session ID is required" }, status = 400 }
            end

            local success, result = pcall(function()
                local stripe = Stripe.new()
                local payment_reference_id = nil

                local session_metadata = {}
                local billing_address_from_session = nil
                local shipping_address_from_session = nil

                if params.session_id then
                    -- Handle Stripe Checkout Session - this will expand customer_details
                    local session, err = stripe:retrieve_checkout_session(params.session_id)

                    if not session then
                        error("Failed to retrieve checkout session: " .. (err or "unknown error"))
                    end

                    if session.payment_status ~= "paid" then
                        error("Payment not completed. Session status: " .. (session.payment_status or "unknown"))
                    end

                    payment_reference_id = session.id
                    session_metadata = session.metadata or {}

                    -- Extract addresses from Stripe's customer_details (actual billing address collected by Stripe)
                    if session.customer_details and session.customer_details.address then
                        local stripe_address = session.customer_details.address
                        -- Convert Stripe address format to our format
                        local address_obj = {
                            name = session.customer_details.name or "",
                            address1 = (stripe_address.line1 or "") .. (stripe_address.line2 and (" " .. stripe_address.line2) or ""),
                            city = stripe_address.city or "",
                            state = stripe_address.state or "",
                            zip = stripe_address.postal_code or "",
                            country = stripe_address.country or ""
                        }
                        billing_address_from_session = cjson.encode(address_obj)
                        shipping_address_from_session = billing_address_from_session -- Use billing as shipping for now

                        ngx.log(ngx.INFO, "Extracted address from Stripe customer_details: " .. billing_address_from_session)
                    else
                        -- Fallback to metadata (if we stored it there)
                        if session_metadata.billing_address then
                            billing_address_from_session = session_metadata.billing_address
                        end
                        if session_metadata.shipping_address then
                            shipping_address_from_session = session_metadata.shipping_address
                        end
                        ngx.log(ngx.WARN, "No customer_details.address found in session, falling back to metadata")
                    end

                    ngx.log(ngx.INFO, "Retrieved session with customer address")
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

                -- Get user UUID from authenticated user (available in self from parent scope)
                local user_uuid = self.current_user and (self.current_user.uuid or self.current_user.sub)
                if not user_uuid or user_uuid == "" then
                    error("Authentication required - no user UUID found in token")
                end

                ngx.log(ngx.INFO, "Confirming payment for user: " .. user_uuid)
                
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

                -- Get or create customer linked to user
                local customer
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
                    customer = CustomerQueries.create({
                        email = params.customer_email or user_data.email,
                        first_name = params.customer_first_name or user_data.first_name,
                        last_name = params.customer_last_name or user_data.last_name,
                        phone = params.customer_phone or user_data.phone_no,
                        user_id = user_id  -- CRITICAL: Link to user!
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

                -- Parse shipping address and extract delivery coordinates via geocoding
                local delivery_latitude = nil
                local delivery_longitude = nil

                -- Use addresses from session metadata if available, otherwise from params
                local billing_address_str = billing_address_from_session or params.billing_address
                local shipping_address_str = shipping_address_from_session or params.shipping_address or billing_address_str

                -- Debug logging
                ngx.log(ngx.INFO, "billing_address_str type: " .. type(billing_address_str))
                ngx.log(ngx.INFO, "billing_address_str value: " .. tostring(billing_address_str))
                ngx.log(ngx.INFO, "shipping_address_str type: " .. type(shipping_address_str))
                ngx.log(ngx.INFO, "shipping_address_str value: " .. tostring(shipping_address_str))

                -- Ensure addresses are JSON strings
                -- If it's a table, encode it
                if type(billing_address_str) == "table" then
                    billing_address_str = cjson.encode(billing_address_str)
                -- If it's a string, validate it's valid JSON (not "[object Object]")
                elseif type(billing_address_str) == "string" then
                    -- Check if it's the invalid "[object Object]" string
                    if billing_address_str == "[object Object]" then
                        ngx.log(ngx.ERR, "Received invalid '[object Object]' string for billing_address")
                        billing_address_str = "{}"
                    else
                        -- Try to parse and re-encode to ensure it's valid JSON
                        local success, parsed = pcall(cjson.decode, billing_address_str)
                        if not success then
                            ngx.log(ngx.ERR, "Invalid JSON in billing_address_str: " .. billing_address_str)
                            billing_address_str = "{}"
                        end
                    end
                end

                if type(shipping_address_str) == "table" then
                    shipping_address_str = cjson.encode(shipping_address_str)
                elseif type(shipping_address_str) == "string" then
                    if shipping_address_str == "[object Object]" then
                        ngx.log(ngx.ERR, "Received invalid '[object Object]' string for shipping_address")
                        shipping_address_str = billing_address_str
                    else
                        local success, parsed = pcall(cjson.decode, shipping_address_str)
                        if not success then
                            ngx.log(ngx.ERR, "Invalid JSON in shipping_address_str: " .. shipping_address_str)
                            shipping_address_str = billing_address_str
                        end
                    end
                end

                -- Geocode the shipping address to get coordinates
                local shipping_addr_success, shipping_addr_obj = pcall(cjson.decode, shipping_address_str)
                if shipping_addr_success and type(shipping_addr_obj) == "table" then
                    -- Initialize geocoding service
                    local geocoder = Geocoding.new()
                    geocoder:ensureCacheTable()

                    -- Attempt to geocode the address
                    local geocode_result, geocode_err = geocoder:geocode(shipping_addr_obj)
                    if geocode_result and geocode_result.lat and geocode_result.lng then
                        delivery_latitude = geocode_result.lat
                        delivery_longitude = geocode_result.lng
                        ngx.log(ngx.INFO, string.format("Geocoded delivery address to: %f, %f (source: %s)",
                            delivery_latitude, delivery_longitude, geocode_result.source or "unknown"))
                    else
                        ngx.log(ngx.WARN, "Geocoding failed: " .. (geocode_err or "unknown error") ..
                            " - Using default coordinates for testing")
                        -- Fallback to default coordinates (Ludhiana, Punjab, India) for testing
                        delivery_latitude = 30.9010
                        delivery_longitude = 75.8573
                    end
                else
                    ngx.log(ngx.WARN, "Could not parse shipping address for geocoding - Using default coordinates")
                    delivery_latitude = 30.9010
                    delivery_longitude = 75.8573
                end

                for store_id, store_order in pairs(store_orders) do
                    local order = OrderQueries.create({
                        store_id = store_id,
                        customer_id = customer and customer.id or nil,
                        subtotal = store_order.subtotal,
                        tax_amount = tax_amount * (store_order.subtotal / subtotal),
                        total_amount = store_order.subtotal + (tax_amount * (store_order.subtotal / subtotal)),
                        billing_address = billing_address_str,
                        shipping_address = shipping_address_str,
                        delivery_latitude = delivery_latitude,
                        delivery_longitude = delivery_longitude,
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