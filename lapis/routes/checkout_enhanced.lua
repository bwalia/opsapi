-- Enhanced Checkout Route with Proper Validation and Error Handling
local respond_to = require("lapis.application").respond_to
local OrderQueries = require("queries.OrderQueries")
local OrderitemQueries = require("queries.OrderitemQueries")
local CustomerQueries = require("queries.CustomerQueries")
local AuthMiddleware = require("middleware.auth")
local CartCalculator = require("lib.cart-calculator")
local ErrorHandler = require("helper.error_handler")
local Sanitizer = require("helper.sanitizer")
local db = require("lapis.db")
local Global = require("helper.global")
local cjson = require("cjson")

return function(app)
    ---
    -- Enhanced checkout endpoint with comprehensive validation
    -- POST /api/v2/checkout-enhanced
    ---
    app:match("checkout_enhanced", "/api/v2/checkout-enhanced", respond_to({
        POST = AuthMiddleware.requireAuth(function(self)
            return ErrorHandler.wrap(function()
                local params = self.params

                -- Step 1: Authenticate and get user
                if not self.current_user or not self.current_user.uuid then
                    return ErrorHandler.unauthorized()
                end
                local user_uuid = self.current_user.uuid

                -- Get user's internal ID
                local user_result = db.select("id from users where uuid = ?", user_uuid)
                if not user_result or #user_result == 0 then
                    return ErrorHandler.notFound("User")
                end
                local user_id = user_result[1].id

                -- Step 2: Validate cart
                local cart_items = db.select("* from cart_items where user_id = ?", user_id)
                if not cart_items or #cart_items == 0 then
                    return ErrorHandler.createErrorResponse(ErrorHandler.ERRORS.CART_EMPTY)
                end

                -- Step 3: Validate and sanitize customer information
                local customer_data = {}

                -- Validate email
                if params.customer_email then
                    local sanitized_email, err = Sanitizer.sanitizeEmail(params.customer_email)
                    if not sanitized_email then
                        return ErrorHandler.validationError("customer_email", err or "Invalid email")
                    end
                    customer_data.email = sanitized_email
                else
                    return ErrorHandler.validationError("customer_email", "Email is required")
                end

                -- Validate and sanitize name fields
                if params.customer_first_name then
                    customer_data.first_name = Sanitizer.sanitizeText(params.customer_first_name, 100)
                    if not customer_data.first_name or customer_data.first_name == "" then
                        return ErrorHandler.validationError("customer_first_name", "First name is required")
                    end
                else
                    return ErrorHandler.validationError("customer_first_name", "First name is required")
                end

                if params.customer_last_name then
                    customer_data.last_name = Sanitizer.sanitizeText(params.customer_last_name, 100)
                end

                -- Validate and sanitize phone
                if params.customer_phone then
                    local sanitized_phone, err = Sanitizer.sanitizePhone(params.customer_phone)
                    if not sanitized_phone then
                        return ErrorHandler.validationError("customer_phone", err or "Invalid phone number")
                    end
                    customer_data.phone = sanitized_phone
                end

                -- Step 4: Validate and sanitize billing address
                local billing_address = params.billing_address

                if not billing_address or type(billing_address) ~= "table" then
                    return ErrorHandler.validationError("billing_address", "Billing address is required")
                end

                -- Validate required address fields
                local required_address_fields = {"name", "address", "city", "state", "country", "zip"}
                for _, field in ipairs(required_address_fields) do
                    if not billing_address[field] or billing_address[field] == "" then
                        return ErrorHandler.validationError("billing_address." .. field, field .. " is required")
                    end
                    -- Sanitize text fields
                    billing_address[field] = Sanitizer.sanitizeText(billing_address[field], 200)
                end

                -- Validate ZIP code format (basic validation)
                if #billing_address.zip < 3 or #billing_address.zip > 20 then
                    return ErrorHandler.validationError("billing_address.zip", "Invalid ZIP code")
                end

                -- Step 5: Validate shipping address (or use billing)
                local shipping_address = params.shipping_address or billing_address

                if type(shipping_address) == "table" then
                    -- Sanitize shipping address fields
                    for field, value in pairs(shipping_address) do
                        shipping_address[field] = Sanitizer.sanitizeText(value, 200)
                    end
                end

                -- Step 6: Sanitize customer notes
                local customer_notes = nil
                if params.customer_notes then
                    customer_notes = Sanitizer.sanitizeText(params.customer_notes, 1000)
                end

                -- Step 7: Validate products availability and stock
                local StoreproductQueries = require("queries.StoreproductQueries")
                local ProductVariantQueries = require("queries.ProductVariantQueries")

                for _, item in ipairs(cart_items) do
                    local product = StoreproductQueries.show(item.product_uuid)

                    if not product then
                        return ErrorHandler.createErrorResponse(
                            ErrorHandler.ERRORS.NOT_FOUND,
                            "Product not found: " .. item.name
                        )
                    end

                    -- Check if product is active
                    if not product.is_active then
                        return ErrorHandler.createErrorResponse(
                            ErrorHandler.ERRORS.VALIDATION_FAILED,
                            "Product is no longer available: " .. item.name
                        )
                    end

                    -- Check stock for product without variants
                    if not item.variant_uuid and product.track_inventory then
                        if tonumber(product.inventory_quantity) < tonumber(item.quantity) then
                            return ErrorHandler.createErrorResponse(
                                ErrorHandler.ERRORS.INSUFFICIENT_STOCK,
                                "Insufficient stock for " .. item.name .. ". Available: " .. product.inventory_quantity
                            )
                        end
                    end

                    -- Check stock for variants
                    if item.variant_uuid then
                        local variant = ProductVariantQueries.show(item.variant_uuid)
                        if not variant or not variant.is_active then
                            return ErrorHandler.createErrorResponse(
                                ErrorHandler.ERRORS.NOT_FOUND,
                                "Product variant not available: " .. (item.variant_title or "")
                            )
                        end

                        if tonumber(variant.inventory_quantity) < tonumber(item.quantity) then
                            return ErrorHandler.createErrorResponse(
                                ErrorHandler.ERRORS.INSUFFICIENT_STOCK,
                                "Insufficient stock for " .. item.name .. " - " .. item.variant_title ..
                                ". Available: " .. variant.inventory_quantity
                            )
                        end
                    end

                    -- Validate price hasn't changed significantly (more than 10%)
                    local current_price = tonumber(product.price)
                    local cart_price = tonumber(item.price)
                    local price_diff_percent = math.abs((current_price - cart_price) / cart_price) * 100

                    if price_diff_percent > 10 then
                        return ErrorHandler.createErrorResponse(
                            ErrorHandler.ERRORS.VALIDATION_FAILED,
                            "Price has changed for " .. item.name .. ". Please review your cart."
                        )
                    end
                end

                -- Step 8: Create or find customer
                local customer = nil
                local existing_customer = db.select("* from customers where email = ? LIMIT 1", customer_data.email)

                if existing_customer and #existing_customer > 0 then
                    customer = existing_customer[1]
                    -- Update customer info
                    db.update("customers", {
                        first_name = customer_data.first_name,
                        last_name = customer_data.last_name,
                        phone = customer_data.phone,
                        updated_at = db.format_date()
                    }, "id = ?", customer.id)
                else
                    customer = CustomerQueries.create(customer_data)
                end

                -- Step 9: Group cart items by store
                local store_orders = {}

                for _, item in ipairs(cart_items) do
                    local product = StoreproductQueries.show(item.product_uuid)
                    local store_id = product.store_id

                    if not store_orders[store_id] then
                        store_orders[store_id] = {items = {}, subtotal = 0}
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

                -- Step 10: Calculate totals
                local cart_totals = CartCalculator.calculateCheckoutTotals(user_id)

                -- Step 11: Create orders for each store
                local created_orders = {}
                local order_numbers = {}

                -- Use database transaction for atomicity
                db.query("BEGIN")

                local success, err = pcall(function()
                    for store_id, store_order in pairs(store_orders) do
                        -- Generate unique order number
                        local order_number = "ORD-" .. os.date("%Y%m%d") .. "-" .. string.upper(string.sub(Global.generateUUID(), 1, 8))

                        -- Calculate store-specific totals
                        local store_subtotal = store_order.subtotal
                        local store_tax = (cart_totals.tax_amount or 0) * (store_subtotal / cart_totals.subtotal)
                        local store_shipping = (cart_totals.shipping_amount or 0) * (store_subtotal / cart_totals.subtotal)
                        local store_total = store_subtotal + store_tax + store_shipping

                        -- Create order
                        local order_data = {
                            uuid = Global.generateUUID(),
                            store_id = store_id,
                            customer_id = customer.id,
                            order_number = order_number,
                            status = "pending",
                            financial_status = "pending",
                            fulfillment_status = "unfulfilled",
                            subtotal = store_subtotal,
                            tax_amount = store_tax,
                            shipping_amount = store_shipping,
                            total_amount = store_total,
                            currency = "USD",
                            billing_address = cjson.encode(billing_address),
                            shipping_address = cjson.encode(shipping_address),
                            customer_notes = customer_notes,
                            processed_at = db.format_date(),
                            created_at = db.format_date(),
                            updated_at = db.format_date()
                        }

                        local order = OrderQueries.create(order_data)

                        -- Create order items and update inventory
                        for _, item in ipairs(store_order.items) do
                            -- Create order item
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

                            -- Update inventory (reserved, not yet deducted)
                            -- Actual deduction happens when order is paid/confirmed
                            -- This is a placeholder for inventory reservation logic
                        end

                        table.insert(created_orders, order)
                        table.insert(order_numbers, order_number)
                    end

                    -- Clear cart after successful order creation
                    db.delete("cart_items", "user_id = ?", user_id)
                end)

                if not success then
                    db.query("ROLLBACK")
                    ngx.log(ngx.ERR, "Checkout failed: " .. tostring(err))
                    return ErrorHandler.internalError("Checkout processing failed", {error = tostring(err)})
                end

                db.query("COMMIT")

                -- Step 12: Return success response
                return {
                    json = {
                        success = true,
                        message = "Order created successfully",
                        orders = created_orders,
                        order_numbers = order_numbers,
                        total_amount = cart_totals.total_amount,
                        customer = {
                            email = customer.email,
                            first_name = customer.first_name,
                            last_name = customer.last_name
                        }
                    },
                    status = 201
                }
            end)(self)
        end)
    }))
end
