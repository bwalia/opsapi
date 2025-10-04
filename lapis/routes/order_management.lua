-- Enhanced Order Management Routes
-- Provides comprehensive order management for sellers with proper validation and error handling

local respond_to = require("lapis.application").respond_to
local AuthMiddleware = require "middleware.auth"
local ErrorHandler = require "helper.error_handler"
local Sanitizer = require "helper.sanitizer"
local db = require("lapis.db")
local cjson = require("cjson")
local Global = require "helper.global"

return function(app)
    ---
    -- Get seller dashboard statistics
    -- GET /api/v2/seller/dashboard/stats
    ---
    app:match("seller_dashboard_stats", "/api/v2/seller/dashboard/stats", respond_to({
        GET = AuthMiddleware.requireAuth(function(self)
            return ErrorHandler.wrap(function()
                local user_uuid = self.current_user.uuid

                -- Get user's internal ID
                local user_result = db.select("id from users where uuid = ?", user_uuid)
                if not user_result or #user_result == 0 then
                    return ErrorHandler.notFound("User")
                end
                local user_id = user_result[1].id

                -- Get all stores owned by user
                local stores = db.select("id, uuid, name from stores where user_id = ?", user_id)

                if not stores or #stores == 0 then
                    return { json = {
                        total_stores = 0,
                        total_products = 0,
                        total_orders = 0,
                        pending_orders = 0,
                        total_revenue = 0,
                        recent_orders = {}
                    } }
                end

                local store_ids = {}
                for _, store in ipairs(stores) do
                    table.insert(store_ids, store.id)
                end

                local store_ids_str = table.concat(store_ids, ",")

                -- Get statistics
                local product_count = db.select(
                    "SELECT COUNT(*) as count FROM storeproducts WHERE store_id IN (" .. store_ids_str .. ")"
                )[1].count or 0

                local order_stats = db.select([[
                    SELECT
                        COUNT(*) as total_orders,
                        COUNT(CASE WHEN status = 'pending' THEN 1 END) as pending_orders,
                        COUNT(CASE WHEN status = 'processing' THEN 1 END) as processing_orders,
                        COUNT(CASE WHEN status = 'shipped' THEN 1 END) as shipped_orders,
                        COUNT(CASE WHEN status = 'delivered' THEN 1 END) as delivered_orders,
                        COALESCE(SUM(CASE WHEN financial_status = 'paid' THEN total_amount ELSE 0 END), 0) as total_revenue
                    FROM orders
                    WHERE store_id IN (]] .. store_ids_str .. [[)
                ]])[1]

                -- Get recent orders (last 10)
                local recent_orders = db.select([[
                    SELECT
                        o.uuid,
                        o.order_number,
                        o.status,
                        o.financial_status,
                        o.total_amount,
                        o.created_at,
                        s.name as store_name,
                        c.email as customer_email,
                        c.first_name as customer_first_name,
                        c.last_name as customer_last_name
                    FROM orders o
                    LEFT JOIN stores s ON o.store_id = s.id
                    LEFT JOIN customers c ON o.customer_id = c.id
                    WHERE o.store_id IN (]] .. store_ids_str .. [[)
                    ORDER BY o.created_at DESC
                    LIMIT 10
                ]])

                return { json = {
                    total_stores = #stores,
                    total_products = tonumber(product_count),
                    total_orders = tonumber(order_stats.total_orders) or 0,
                    pending_orders = tonumber(order_stats.pending_orders) or 0,
                    processing_orders = tonumber(order_stats.processing_orders) or 0,
                    shipped_orders = tonumber(order_stats.shipped_orders) or 0,
                    delivered_orders = tonumber(order_stats.delivered_orders) or 0,
                    total_revenue = tonumber(order_stats.total_revenue) or 0,
                    recent_orders = recent_orders or {}
                } }
            end)(self)
        end)
    }))

    ---
    -- Get seller's orders with advanced filtering and pagination
    -- GET /api/v2/seller/orders?page=1&limit=20&status=pending&store_id=xxx
    ---
    app:match("seller_orders_list", "/api/v2/seller/orders", respond_to({
        GET = AuthMiddleware.requireAuth(function(self)
            return ErrorHandler.wrap(function()
                local user_uuid = self.current_user.uuid

                -- Get user's internal ID
                local user_result = db.select("id from users where uuid = ?", user_uuid)
                if not user_result or #user_result == 0 then
                    return ErrorHandler.notFound("User")
                end
                local user_id = user_result[1].id

                -- Parse and sanitize query parameters
                local page = Sanitizer.sanitizeInteger(self.params.page or 1, 1, 10000) or 1
                local limit = Sanitizer.sanitizeInteger(self.params.limit or 20, 1, 100) or 20
                local offset = (page - 1) * limit

                local status_filter = self.params.status
                local store_filter = self.params.store_id
                local search_query = self.params.search

                -- Build WHERE clause
                local where_conditions = {"s.user_id = ?"}
                local where_params = {user_id}

                -- Add status filter
                if status_filter and status_filter ~= "" then
                    local valid, err = ErrorHandler.validateEnum(status_filter, "status", {
                        "pending", "confirmed", "processing", "shipped", "delivered", "cancelled", "refunded"
                    })
                    if not valid then return err end

                    table.insert(where_conditions, "o.status = ?")
                    table.insert(where_params, status_filter)
                end

                -- Add store filter
                if store_filter and store_filter ~= "" then
                    table.insert(where_conditions, "s.uuid = ?")
                    table.insert(where_params, store_filter)
                end

                -- Add search filter (order number or customer)
                if search_query and search_query ~= "" then
                    local search_safe = Sanitizer.sanitizeText(search_query, 100)
                    table.insert(where_conditions, "(o.order_number LIKE ? OR c.email LIKE ? OR c.first_name LIKE ? OR c.last_name LIKE ?)")
                    local search_pattern = "%" .. search_safe .. "%"
                    table.insert(where_params, search_pattern)
                    table.insert(where_params, search_pattern)
                    table.insert(where_params, search_pattern)
                    table.insert(where_params, search_pattern)
                end

                local where_clause = table.concat(where_conditions, " AND ")

                -- Get total count
                local count_query = [[
                    SELECT COUNT(*) as total
                    FROM orders o
                    LEFT JOIN stores s ON o.store_id = s.id
                    LEFT JOIN customers c ON o.customer_id = c.id
                    WHERE ]] .. where_clause

                local total_result = db.select(count_query, unpack(where_params))
                local total = total_result[1].total or 0

                -- Get orders
                local orders_query = [[
                    SELECT
                        o.uuid,
                        o.order_number,
                        o.status,
                        o.financial_status,
                        o.fulfillment_status,
                        o.subtotal,
                        o.tax_amount,
                        o.shipping_amount,
                        o.total_amount,
                        o.created_at,
                        o.updated_at,
                        s.uuid as store_uuid,
                        s.name as store_name,
                        c.email as customer_email,
                        c.first_name as customer_first_name,
                        c.last_name as customer_last_name,
                        c.phone as customer_phone
                    FROM orders o
                    LEFT JOIN stores s ON o.store_id = s.id
                    LEFT JOIN customers c ON o.customer_id = c.id
                    WHERE ]] .. where_clause .. [[
                    ORDER BY o.created_at DESC
                    LIMIT ? OFFSET ?
                ]]

                table.insert(where_params, limit)
                table.insert(where_params, offset)

                local orders = db.select(orders_query, unpack(where_params))

                -- Get item counts for each order
                for _, order in ipairs(orders) do
                    local item_count = db.select([[
                        SELECT COUNT(*) as count
                        FROM orderitems
                        WHERE order_id = (SELECT id FROM orders WHERE uuid = ?)
                    ]], order.uuid)[1].count or 0

                    order.item_count = tonumber(item_count)
                end

                return { json = {
                    data = orders,
                    pagination = {
                        page = page,
                        limit = limit,
                        total = tonumber(total),
                        total_pages = math.ceil(tonumber(total) / limit)
                    }
                } }
            end)(self)
        end)
    }))

    ---
    -- Get single order details with items
    -- GET /api/v2/seller/orders/:order_uuid
    ---
    app:match("seller_order_details", "/api/v2/seller/orders/:order_uuid", respond_to({
        GET = AuthMiddleware.requireAuth(function(self)
            return ErrorHandler.wrap(function()
                local order_uuid = self.params.order_uuid
                local user_uuid = self.current_user.uuid

                -- Validate UUID
                local valid, err = ErrorHandler.validateUUID(order_uuid, "order_uuid")
                if not valid then return err end

                -- Get user ID
                local user_result = db.select("id from users where uuid = ?", user_uuid)
                if not user_result or #user_result == 0 then
                    return ErrorHandler.notFound("User")
                end
                local user_id = user_result[1].id

                -- Get order with authorization check
                local orders = db.select([[
                    SELECT
                        o.*,
                        s.uuid as store_uuid,
                        s.name as store_name,
                        s.user_id as store_owner_id,
                        c.uuid as customer_uuid,
                        c.email as customer_email,
                        c.first_name as customer_first_name,
                        c.last_name as customer_last_name,
                        c.phone as customer_phone,
                        c.addresses as customer_addresses
                    FROM orders o
                    LEFT JOIN stores s ON o.store_id = s.id
                    LEFT JOIN customers c ON o.customer_id = c.id
                    WHERE o.uuid = ? AND s.user_id = ?
                ]], order_uuid, user_id)

                if not orders or #orders == 0 then
                    return ErrorHandler.notFound("Order")
                end

                local order = orders[1]

                -- Parse JSON fields
                if order.billing_address then
                    local success, parsed = pcall(cjson.decode, order.billing_address)
                    if success then order.billing_address = parsed end
                end

                if order.shipping_address then
                    local success, parsed = pcall(cjson.decode, order.shipping_address)
                    if success then order.shipping_address = parsed end
                end

                if order.customer_addresses then
                    local success, parsed = pcall(cjson.decode, order.customer_addresses)
                    if success then order.customer_addresses = parsed end
                end

                -- Get order items
                local items = db.select([[
                    SELECT
                        oi.*,
                        sp.uuid as product_uuid,
                        sp.name as current_product_name,
                        sp.images as product_images
                    FROM orderitems oi
                    LEFT JOIN storeproducts sp ON oi.product_id = sp.id
                    WHERE oi.order_id = ?
                ]], order.id)

                -- Parse product images
                for _, item in ipairs(items) do
                    if item.product_images then
                        local success, parsed = pcall(cjson.decode, item.product_images)
                        if success and parsed and #parsed > 0 then
                            item.product_image = parsed[1]
                        end
                    end
                end

                order.items = items

                -- Get order history (if exists)
                local history = db.select([[
                    SELECT *
                    FROM order_history
                    WHERE order_id = ?
                    ORDER BY created_at DESC
                ]], order.id)

                order.history = history or {}

                return { json = order }
            end)(self)
        end)
    }))

    ---
    -- Update order status with validation and audit trail
    -- PUT /api/v2/seller/orders/:order_uuid/status
    ---
    app:match("seller_update_order_status", "/api/v2/seller/orders/:order_uuid/status", respond_to({
        PUT = AuthMiddleware.requireAuth(function(self)
            return ErrorHandler.wrap(function()
                local order_uuid = self.params.order_uuid
                local user_uuid = self.current_user.uuid

                -- Validate UUID
                local valid, err = ErrorHandler.validateUUID(order_uuid, "order_uuid")
                if not valid then return err end

                -- Sanitize and validate input
                local new_status = self.params.status
                local new_financial_status = self.params.financial_status
                local new_fulfillment_status = self.params.fulfillment_status
                local tracking_number = self.params.tracking_number
                local carrier = self.params.carrier
                local internal_notes = self.params.internal_notes

                -- Validate at least one field is being updated
                if not new_status and not new_financial_status and not new_fulfillment_status then
                    return ErrorHandler.validationError(nil, "At least one status field must be provided")
                end

                -- Validate status values
                if new_status then
                    local valid, err = ErrorHandler.validateEnum(new_status, "status", {
                        "pending", "confirmed", "processing", "shipped", "delivered", "cancelled", "refunded"
                    })
                    if not valid then return err end
                end

                if new_financial_status then
                    local valid, err = ErrorHandler.validateEnum(new_financial_status, "financial_status", {
                        "pending", "authorized", "partially_paid", "paid", "partially_refunded", "refunded", "voided"
                    })
                    if not valid then return err end
                end

                if new_fulfillment_status then
                    local valid, err = ErrorHandler.validateEnum(new_fulfillment_status, "fulfillment_status", {
                        "unfulfilled", "partial", "fulfilled", "cancelled"
                    })
                    if not valid then return err end
                end

                -- Sanitize text fields
                if tracking_number then
                    tracking_number = Sanitizer.sanitizeText(tracking_number, 100)
                end

                if carrier then
                    carrier = Sanitizer.sanitizeText(carrier, 100)
                end

                if internal_notes then
                    internal_notes = Sanitizer.sanitizeText(internal_notes, 1000)
                end

                -- Get user ID
                local user_result = db.select("id from users where uuid = ?", user_uuid)
                if not user_result or #user_result == 0 then
                    return ErrorHandler.notFound("User")
                end
                local user_id = user_result[1].id

                -- Get order with current status and verify ownership
                local orders = db.select([[
                    SELECT o.*, s.user_id as store_owner_id
                    FROM orders o
                    LEFT JOIN stores s ON o.store_id = s.id
                    WHERE o.uuid = ? AND s.user_id = ?
                ]], order_uuid, user_id)

                if not orders or #orders == 0 then
                    return ErrorHandler.notFound("Order")
                end

                local order = orders[1]

                -- Validate status transitions
                local function isValidTransition(from_status, to_status)
                    local transitions = {
                        pending = {confirmed = true, cancelled = true},
                        confirmed = {processing = true, cancelled = true},
                        processing = {shipped = true, cancelled = true},
                        shipped = {delivered = true},
                        delivered = {refunded = true},
                        cancelled = {},  -- Cannot transition from cancelled
                        refunded = {}    -- Cannot transition from refunded
                    }

                    if not from_status or not to_status then return true end
                    if from_status == to_status then return true end  -- No change

                    local allowed = transitions[from_status]
                    return allowed and allowed[to_status] or false
                end

                if new_status and not isValidTransition(order.status, new_status) then
                    return ErrorHandler.createErrorResponse(
                        ErrorHandler.ERRORS.ORDER_INVALID_STATUS,
                        "Cannot transition from '" .. order.status .. "' to '" .. new_status .. "'"
                    )
                end

                -- Build update data
                local update_data = {
                    updated_at = db.format_date()
                }

                if new_status then update_data.status = new_status end
                if new_financial_status then update_data.financial_status = new_financial_status end
                if new_fulfillment_status then update_data.fulfillment_status = new_fulfillment_status end
                if internal_notes then update_data.internal_notes = internal_notes end

                -- Update order
                db.update("orders", update_data, "uuid = ?", order_uuid)

                -- Log to order history
                local history_entry = {
                    order_id = order.id,
                    user_id = user_id,
                    action = "status_update",
                    old_status = order.status,
                    new_status = new_status or order.status,
                    old_financial_status = order.financial_status,
                    new_financial_status = new_financial_status or order.financial_status,
                    old_fulfillment_status = order.fulfillment_status,
                    new_fulfillment_status = new_fulfillment_status or order.fulfillment_status,
                    notes = internal_notes,
                    tracking_number = tracking_number,
                    carrier = carrier,
                    created_at = db.format_date()
                }

                -- Only insert history if order_history table exists
                pcall(function()
                    db.insert("order_history", history_entry)
                end)

                return { json = {
                    message = "Order status updated successfully",
                    order_uuid = order_uuid,
                    status = new_status or order.status,
                    financial_status = new_financial_status or order.financial_status,
                    fulfillment_status = new_fulfillment_status or order.fulfillment_status
                } }
            end)(self)
        end)
    }))
end
