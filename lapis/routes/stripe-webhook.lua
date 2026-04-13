local respond_to = require("lapis.application").respond_to
local cjson = require("cjson")
local Global = require("helper.global")
local Geocoding = require("lib.Geocoding")
local db = require("lapis.db")
local NotificationHelper = require("helper.notification-helper")

-- Helper function: Convert cjson.null to nil
local function null_to_nil(value)
    if value == cjson.null then
        return nil
    end
    return value
end

-- Helper function: Safely convert value to string or nil
local function to_string_or_nil(value)
    if value == nil or value == cjson.null then
        return nil
    end
    return tostring(value)
end

-- Helper function: Handle payment_intent.succeeded
local function handle_payment_intent_succeeded(self, event)
    local success, result = pcall(function()
        local payment_intent = event.data.object
        local payment_intent_id = payment_intent.id

        ngx.log(ngx.INFO, "Processing payment_intent.succeeded: " .. payment_intent_id)

        -- Check if payment record already exists
        local existing = db.select("* FROM payments WHERE stripe_payment_intent_id = ?", payment_intent_id)
        if existing and #existing > 0 then
            ngx.log(ngx.INFO, "Payment record already exists for: " .. payment_intent_id)
            return { json = { received = true }, status = 200 }
        end

        -- Extract payment details
        local payment_method = payment_intent.payment_method
        local amount = payment_intent.amount / 100 -- Convert from cents
        local currency = payment_intent.currency
        local customer_id = payment_intent.customer

        -- Get payment method details if available
        local card_brand = nil
        local card_last4 = nil
        local payment_method_type = nil

        if payment_intent.charges and payment_intent.charges.data and #payment_intent.charges.data > 0 then
            local charge = payment_intent.charges.data[1]
            if charge.payment_method_details then
                payment_method_type = charge.payment_method_details.type
                if charge.payment_method_details.card then
                    card_brand = charge.payment_method_details.card.brand
                    card_last4 = charge.payment_method_details.card.last4
                end
            end
        end

        -- Create payment record
        local payment_uuid = Global.generateUUID()
        local payment = db.insert("payments", {
            uuid = payment_uuid,
            stripe_payment_intent_id = payment_intent_id,
            stripe_charge_id = null_to_nil(payment_intent.latest_charge),
            stripe_customer_id = null_to_nil(customer_id),
            stripe_payment_method_id = null_to_nil(payment_method),
            amount = amount,
            currency = currency,
            status = "succeeded",
            payment_method_type = null_to_nil(payment_method_type),
            card_brand = null_to_nil(card_brand),
            card_last4 = null_to_nil(card_last4),
            receipt_email = null_to_nil(payment_intent.receipt_email),
            receipt_url = payment_intent.charges and payment_intent.charges.data[1] and null_to_nil(payment_intent.charges.data[1].receipt_url) or nil,
            metadata = cjson.encode(payment_intent.metadata or {}),
            stripe_raw_response = cjson.encode(event),
            created_at = db.format_date(),
            updated_at = db.format_date()
        })

        ngx.log(ngx.INFO, "Payment record created: " .. payment_uuid)

        -- Update related orders if exists in metadata
        if payment_intent.metadata then
            -- Handle multiple orders (comma-separated order_uuids)
            local order_uuids = payment_intent.metadata.order_uuids or payment_intent.metadata.order_id
            if order_uuids then
                for order_uuid in string.gmatch(order_uuids, "[^,]+") do
                    order_uuid = order_uuid:match("^%s*(.-)%s*$") -- trim whitespace

                    local orders = db.select("* FROM orders WHERE uuid = ?", order_uuid)
                    if orders and #orders > 0 then
                        db.update("orders", {
                            payment_id = payment.id,
                            financial_status = "paid",
                            updated_at = db.format_date()
                        }, "uuid = ?", order_uuid)

                        ngx.log(ngx.INFO, "Order updated with payment: " .. order_uuid)

                        -- Send notification to customer
                        pcall(function()
                            NotificationHelper.notifyOrderStatusChange(orders[1].id, orders[1].status, orders[1].status)
                        end)
                    end
                end
            end
        end

        return { json = { received = true }, status = 200 }
    end)

    if not success then
        ngx.log(ngx.ERR, "Error in handle_payment_intent_succeeded: " .. tostring(result))
        return { json = { error = "Internal error" }, status = 500 }
    end

    return result
end

-- Helper function: Handle checkout.session.completed
local function handle_checkout_session_completed(self, event)
    local success, result = pcall(function()
        local session = event.data.object
        local session_id = session.id

        ngx.log(ngx.INFO, "Processing checkout.session.completed: " .. session_id)

        -- Only process if payment was successful
        if session.payment_status ~= "paid" then
            ngx.log(ngx.INFO, "Checkout session not paid: " .. session.payment_status)
            return { json = { received = true }, status = 200 }
        end

        -- Check if payment record already exists
        local existing = db.select("* FROM payments WHERE stripe_payment_intent_id = ?", session.payment_intent)
        if existing and #existing > 0 then
            ngx.log(ngx.INFO, "Payment record already exists for session: " .. session_id)
            return { json = { received = true }, status = 200 }
        end

        -- Extract metadata
        local metadata = session.metadata or {}
        local user_id = tonumber(metadata.user_id)
        local customer_id = tonumber(metadata.customer_id)

        if not user_id or not customer_id then
            ngx.log(ngx.ERR, "Missing user_id or customer_id in session metadata")
            return { json = { error = "Missing required metadata" }, status = 400 }
        end

        -- Extract details
        local amount = session.amount_total / 100 -- Convert from cents
        local currency = session.currency or "usd"

        -- Create payment record
        local payment_uuid = Global.generateUUID()
        db.insert("payments", {
            uuid = payment_uuid,
            stripe_payment_intent_id = null_to_nil(session.payment_intent),
            stripe_customer_id = null_to_nil(session.customer),
            amount = amount,
            currency = currency,
            status = "succeeded",
            receipt_email = null_to_nil(session.customer_email) or (session.customer_details and null_to_nil(session.customer_details.email)) or nil,
            metadata = cjson.encode(metadata),
            stripe_raw_response = cjson.encode(event),
            created_at = db.format_date(),
            updated_at = db.format_date()
        })

        -- Get the inserted payment record with ID
        local payment_result = db.select("* FROM payments WHERE uuid = ?", payment_uuid)
        if not payment_result or #payment_result == 0 then
            error("Failed to retrieve created payment record")
        end
        local payment = payment_result[1]

        ngx.log(ngx.INFO, "Payment record created from checkout session: " .. payment_uuid .. " (ID: " .. payment.id .. ")")

        -- Get cart items for this user
        local cart_items = db.select("* from cart_items where user_id = ?", user_id)
        if not cart_items or #cart_items == 0 then
            ngx.log(ngx.WARN, "No cart items found for user_id: " .. user_id)
            return { json = { received = true }, status = 200 }
        end

        -- Extract addresses from Stripe customer_details (actual billing address collected by Stripe)
        local billing_address = "{}"
        local shipping_address_str = "{}"
        local customer_notes = metadata.customer_notes or ""

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
            billing_address = cjson.encode(address_obj)
            shipping_address_str = billing_address

            ngx.log(ngx.INFO, "Extracted address from webhook customer_details: " .. billing_address)
        else
            -- Fallback to metadata
            billing_address = metadata.billing_address or "{}"
            shipping_address_str = metadata.shipping_address or billing_address
            ngx.log(ngx.WARN, "No customer_details.address in webhook event, using metadata")
        end

        -- Parse shipping address and geocode to extract delivery coordinates
        local delivery_latitude = nil
        local delivery_longitude = nil

        -- Try to parse shipping address JSON
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
                ngx.log(ngx.INFO, string.format("Webhook: Geocoded delivery address to: %f, %f (source: %s)",
                    delivery_latitude, delivery_longitude, geocode_result.source or "unknown"))
            else
                ngx.log(ngx.WARN, "Webhook: Geocoding failed: " .. (geocode_err or "unknown error") ..
                    " - Using default coordinates for testing")
                -- Fallback to default coordinates (Ludhiana, Punjab, India) for testing
                delivery_latitude = 30.9010
                delivery_longitude = 75.8573
            end
        else
            ngx.log(ngx.WARN, "Webhook: Could not parse shipping address for geocoding - Using default coordinates")
            delivery_latitude = 30.9010
            delivery_longitude = 75.8573
        end

        -- Group cart items by store
        local StoreproductQueries = require("queries.StoreproductQueries")
        local OrderQueries = require("queries.OrderQueries")
        local OrderitemQueries = require("queries.OrderitemQueries")

        local store_orders = {}
        local total_subtotal = 0

        for _, item in ipairs(cart_items) do
            local product = StoreproductQueries.show(item.product_uuid)
            if product then
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
                total_subtotal = total_subtotal + item_total
            end
        end

        -- Parse totals from metadata
        local tax_amount = tonumber(metadata.tax_amount) or 0
        local shipping_amount = tonumber(metadata.shipping_amount) or 0

        -- Create orders for each store
        for store_id, store_order in pairs(store_orders) do
            -- Generate unique order number
            local order_number = "ORD-" .. os.date("%Y%m%d") .. "-" .. string.upper(string.sub(Global.generateUUID(), 1, 8))

            -- Calculate store-specific totals (proportional)
            local store_subtotal = store_order.subtotal
            local store_tax = tax_amount * (store_subtotal / total_subtotal)
            local store_shipping = shipping_amount * (store_subtotal / total_subtotal)
            local store_total = store_subtotal + store_tax + store_shipping

            local order_data = {
                uuid = Global.generateUUID(),
                store_id = store_id,
                customer_id = customer_id,
                order_number = order_number,
                status = "pending",
                financial_status = "paid",
                fulfillment_status = "unfulfilled",
                subtotal = store_subtotal,
                tax_amount = store_tax,
                shipping_amount = store_shipping,
                total_amount = store_total,
                currency = currency,
                billing_address = billing_address,
                shipping_address = shipping_address_str,
                delivery_latitude = delivery_latitude,
                delivery_longitude = delivery_longitude,
                customer_notes = customer_notes ~= "" and customer_notes or nil,
                payment_id = payment.id,
                stripe_customer_id = null_to_nil(session.customer),
                processed_at = db.format_date(),
                created_at = db.format_date(),
                updated_at = db.format_date()
            }

            local order = OrderQueries.create(order_data)
            ngx.log(ngx.INFO, "Order created: " .. order.order_number)

            -- Create order items
            for _, item in ipairs(store_order.items) do
                OrderitemQueries.create({
                    uuid = Global.generateUUID(),
                    order_id = order.id,
                    product_id = item.product.id,
                    variant_id = null_to_nil(item.variant_uuid),
                    quantity = item.quantity,
                    price = item.price,
                    total = item.total,
                    product_title = item.product.name,
                    variant_title = null_to_nil(item.variant_title),
                    sku = null_to_nil(item.product.sku),
                    created_at = db.format_date(),
                    updated_at = db.format_date()
                })
            end

            -- Send notification
            pcall(function()
                NotificationHelper.notifyOrderCreated(order.id)
            end)
        end

        -- Clear cart after successful order creation
        db.delete("cart_items", "user_id = ?", user_id)
        ngx.log(ngx.INFO, "Cart cleared for user_id: " .. user_id)

        return { json = { received = true }, status = 200 }
    end)

    if not success then
        ngx.log(ngx.ERR, "Error in handle_checkout_session_completed: " .. tostring(result))
        return { json = { error = "Internal error" }, status = 500 }
    end

    return result
end

-- Helper function: Handle charge.succeeded
local function handle_charge_succeeded(self, event)
    local success, result = pcall(function()
        local charge = event.data.object
        local charge_id = charge.id

        ngx.log(ngx.INFO, "Processing charge.succeeded: " .. charge_id)

        -- Update existing payment record if it exists
        local payments = db.select("* FROM payments WHERE stripe_payment_intent_id = ? OR stripe_charge_id = ?",
            charge.payment_intent, charge_id)

        if payments and #payments > 0 then
            local payment = payments[1]
            db.update("payments", {
                stripe_charge_id = charge_id,
                receipt_url = null_to_nil(charge.receipt_url) or payment.receipt_url,
                card_brand = (charge.payment_method_details and charge.payment_method_details.card and null_to_nil(charge.payment_method_details.card.brand)) or payment.card_brand,
                card_last4 = (charge.payment_method_details and charge.payment_method_details.card and null_to_nil(charge.payment_method_details.card.last4)) or payment.card_last4,
                updated_at = db.format_date()
            }, "id = ?", payment.id)

            ngx.log(ngx.INFO, "Payment updated with charge: " .. payment.uuid)
        end

        return { json = { received = true }, status = 200 }
    end)

    if not success then
        ngx.log(ngx.ERR, "Error in handle_charge_succeeded: " .. tostring(result))
        return { json = { error = "Internal error" }, status = 500 }
    end

    return result
end

-- Helper function: Handle charge.refunded
local function handle_charge_refunded(self, event)
    local success, result = pcall(function()
        local charge = event.data.object
        local charge_id = charge.id

        ngx.log(ngx.INFO, "Processing charge.refunded: " .. charge_id)

        -- Find payment record
        local payments = db.select("* FROM payments WHERE stripe_charge_id = ?", charge_id)

        if payments and #payments > 0 then
            local payment = payments[1]

            -- Update payment status
            db.update("payments", {
                status = charge.refunded and "refunded" or "partially_refunded",
                updated_at = db.format_date()
            }, "id = ?", payment.id)

            -- Create refund record
            local refund_uuid = Global.generateUUID()
            local refund_amount = charge.amount_refunded / 100

            -- Find order linked to this payment
            local orders = db.select("* FROM orders WHERE payment_id = ?", payment.id)
            local order_id = orders and #orders > 0 and orders[1].id or nil

            db.insert("refunds", {
                uuid = refund_uuid,
                order_id = null_to_nil(order_id),
                payment_id = payment.id,
                stripe_refund_id = (charge.refunds and charge.refunds.data[1] and null_to_nil(charge.refunds.data[1].id)) or nil,
                amount = refund_amount,
                reason = (charge.refunds and charge.refunds.data[1] and null_to_nil(charge.refunds.data[1].reason)) or nil,
                status = "succeeded",
                refund_type = charge.refunded and "full" or "partial",
                created_at = db.format_date(),
                updated_at = db.format_date()
            })

            -- Update order status if fully refunded
            if charge.refunded and order_id then
                db.update("orders", {
                    status = "refunded",
                    financial_status = "refunded",
                    updated_at = db.format_date()
                }, "id = ?", order_id)

                -- Notify customer
                pcall(function()
                    NotificationHelper.notifyOrderStatusChange(order_id, "delivered", "refunded")
                end)
            end

            ngx.log(ngx.INFO, "Refund processed: " .. refund_uuid)
        end

        return { json = { received = true }, status = 200 }
    end)

    if not success then
        ngx.log(ngx.ERR, "Error in handle_charge_refunded: " .. tostring(result))
        return { json = { error = "Internal error" }, status = 500 }
    end

    return result
end

-- Helper function: Handle payment_intent.payment_failed
local function handle_payment_failed(self, event)
    local success, result = pcall(function()
        local payment_intent = event.data.object
        local payment_intent_id = payment_intent.id

        ngx.log(ngx.ERR, "Processing payment_intent.payment_failed: " .. payment_intent_id)

        -- Update or create payment record with failed status
        local existing = db.select("* FROM payments WHERE stripe_payment_intent_id = ?", payment_intent_id)

        if existing and #existing > 0 then
            db.update("payments", {
                status = "failed",
                updated_at = db.format_date()
            }, "stripe_payment_intent_id = ?", payment_intent_id)
        else
            local payment_uuid = Global.generateUUID()
            db.insert("payments", {
                uuid = payment_uuid,
                stripe_payment_intent_id = payment_intent_id,
                stripe_customer_id = null_to_nil(payment_intent.customer),
                amount = payment_intent.amount / 100,
                currency = null_to_nil(payment_intent.currency) or "usd",
                status = "failed",
                metadata = cjson.encode(payment_intent.metadata or {}),
                stripe_raw_response = cjson.encode(event),
                created_at = db.format_date(),
                updated_at = db.format_date()
            })
        end

        -- Update orders to failed status if linked
        if payment_intent.metadata and payment_intent.metadata.order_uuids then
            for order_uuid in string.gmatch(payment_intent.metadata.order_uuids, "[^,]+") do
                order_uuid = order_uuid:match("^%s*(.-)%s*$")

                db.update("orders", {
                    financial_status = "failed",
                    updated_at = db.format_date()
                }, "uuid = ?", order_uuid)
            end
        end

        return { json = { received = true }, status = 200 }
    end)

    if not success then
        ngx.log(ngx.ERR, "Error in handle_payment_failed: " .. tostring(result))
        return { json = { error = "Internal error" }, status = 500 }
    end

    return result
end

-- Main route handler
return function(app)
    -- Stripe Webhook Handler
    app:match("stripe_webhook", "/api/v2/webhooks/stripe", respond_to({
        POST = function(self)
            -- Get raw body
            ngx.req.read_body()
            local body = ngx.req.get_body_data()

            if not body then
                ngx.log(ngx.ERR, "Stripe webhook: No body received")
                return { json = { error = "No body" }, status = 400 }
            end

            -- Verify Stripe signature (commented out for development, enable in production)
            local stripe_signature = ngx.var.http_stripe_signature
            if not stripe_signature then
                ngx.log(ngx.WARN, "Stripe webhook: No signature header (development mode)")
                -- In production, uncomment this:
                -- return { json = { error = "No signature" }, status = 401 }
            end

            -- Parse the event
            local success, event = pcall(cjson.decode, body)
            if not success then
                ngx.log(ngx.ERR, "Stripe webhook: Invalid JSON - " .. tostring(event))
                return { json = { error = "Invalid JSON" }, status = 400 }
            end

            ngx.log(ngx.INFO, "Stripe webhook received: " .. event.type)

            -- Handle different event types
            if event.type == "payment_intent.succeeded" then
                return handle_payment_intent_succeeded(self, event)
            elseif event.type == "checkout.session.completed" then
                return handle_checkout_session_completed(self, event)
            elseif event.type == "charge.succeeded" then
                return handle_charge_succeeded(self, event)
            elseif event.type == "charge.refunded" then
                return handle_charge_refunded(self, event)
            elseif event.type == "payment_intent.payment_failed" then
                return handle_payment_failed(self, event)
            else
                ngx.log(ngx.INFO, "Stripe webhook: Unhandled event type - " .. event.type)
                return { json = { received = true }, status = 200 }
            end
        end
    }))
end
