local respond_to = require("lapis.application").respond_to
local OrderQueries = require "queries.OrderQueries"
local AuthMiddleware = require "middleware.auth"
local db = require("lapis.db")
local cjson = require("cjson")

-- Configure cjson to encode empty tables as arrays
cjson.encode_empty_table_as_object(false)

return function(app)

    -- Helper function to get user's role
    local function getUserRole(user_uuid)
        local result = db.query([[
            SELECT r.role_name
            FROM user__roles ur
            JOIN roles r ON ur.role_id = r.id
            JOIN users u ON ur.user_id = u.id
            WHERE u.uuid = ?
            LIMIT 1
        ]], user_uuid)
        return result and result[1] and result[1].role_name or nil
    end

    -- Helper function to get user's stores (for sellers)
    local function getUserStores(user_uuid)
        local result = db.query([[
            SELECT s.id, s.uuid, s.name
            FROM stores s
            JOIN users u ON s.user_id = u.id
            WHERE u.uuid = ?
        ]], user_uuid)
        return result or {}
    end

    -- Helper function to build WHERE clause for filters
    local function buildWhereClause(params, user_role, user_stores)
        local conditions = {}

        -- Role-based filtering
        if user_role ~= "administrative" then
            -- Seller: only see orders from their stores
            if #user_stores > 0 then
                local store_ids = {}
                for _, store in ipairs(user_stores) do
                    table.insert(store_ids, store.id)
                end
                table.insert(conditions, "o.store_id IN (" .. table.concat(store_ids, ",") .. ")")
            else
                -- No stores, return no orders
                table.insert(conditions, "1 = 0")
            end
        end

        -- Status filter
        if params.status and params.status ~= "" and params.status ~= "all" then
            table.insert(conditions, "o.status = " .. db.escape_literal(params.status))
        end

        -- Payment status filter
        if params.payment_status and params.payment_status ~= "" and params.payment_status ~= "all" then
            table.insert(conditions, "o.financial_status = " .. db.escape_literal(params.payment_status))
        end

        -- Fulfillment status filter
        if params.fulfillment_status and params.fulfillment_status ~= "" and params.fulfillment_status ~= "all" then
            table.insert(conditions, "o.fulfillment_status = " .. db.escape_literal(params.fulfillment_status))
        end

        -- Store filter (admin can filter by store)
        if params.store_uuid and params.store_uuid ~= "" and params.store_uuid ~= "all" then
            table.insert(conditions, "s.uuid = " .. db.escape_literal(params.store_uuid))
        end

        -- Date range filter
        if params.date_from and params.date_from ~= "" then
            table.insert(conditions, "o.created_at >= " .. db.escape_literal(params.date_from))
        end
        if params.date_to and params.date_to ~= "" then
            table.insert(conditions, "o.created_at <= " .. db.escape_literal(params.date_to .. " 23:59:59"))
        end

        -- Search filter (order number, customer email, customer name)
        if params.search and params.search ~= "" then
            local search_term = "%" .. params.search .. "%"
            local search_escaped = db.escape_literal(search_term)
            table.insert(conditions, "(o.order_number ILIKE " .. search_escaped ..
                " OR c.email ILIKE " .. search_escaped ..
                " OR c.first_name ILIKE " .. search_escaped ..
                " OR c.last_name ILIKE " .. search_escaped ..
                " OR CONCAT(c.first_name, ' ', c.last_name) ILIKE " .. search_escaped .. ")")
        end

        if #conditions > 0 then
            return "WHERE " .. table.concat(conditions, " AND ")
        end
        return ""
    end

    -- Get orders with role-based access control and server-side pagination
    app:match("orders", "/api/v2/orders", respond_to({
        GET = AuthMiddleware.requireAuth(function(self)
            local user_uuid = self.current_user.uuid
            local user_role = getUserRole(user_uuid)
            local user_stores = getUserStores(user_uuid)

            -- Pagination params
            local page = tonumber(self.params.page) or 1
            local per_page = tonumber(self.params.per_page) or tonumber(self.params.limit) or 10
            local offset = (page - 1) * per_page

            -- Sorting params
            local order_by = self.params.order_by or "created_at"
            local order_dir = self.params.order_dir or "desc"

            -- Validate order_by to prevent SQL injection
            local valid_order_fields = {
                created_at = "o.created_at",
                updated_at = "o.updated_at",
                order_number = "o.order_number",
                total_amount = "o.total_amount",
                status = "o.status",
                customer_name = "c.first_name"
            }
            local order_field = valid_order_fields[order_by] or "o.created_at"
            order_dir = order_dir == "asc" and "ASC" or "DESC"

            -- Build WHERE clause
            local where_clause = buildWhereClause(self.params, user_role, user_stores)

            -- Get total count
            local count_query = [[
                SELECT COUNT(*) as total
                FROM orders o
                LEFT JOIN customers c ON o.customer_id = c.id
                LEFT JOIN stores s ON o.store_id = s.id
            ]] .. where_clause

            local count_result = db.query(count_query)
            local total = count_result and count_result[1] and count_result[1].total or 0

            -- Get paginated orders with related data
            local orders_query = [[
                SELECT
                    o.id,
                    o.uuid,
                    o.order_number,
                    o.status,
                    o.financial_status,
                    o.fulfillment_status,
                    o.subtotal,
                    o.tax_amount,
                    o.shipping_amount,
                    o.discount_amount,
                    o.total_amount,
                    o.currency,
                    o.customer_notes,
                    o.internal_notes,
                    o.billing_address,
                    o.shipping_address,
                    o.created_at,
                    o.updated_at,
                    c.uuid as customer_uuid,
                    c.email as customer_email,
                    c.first_name as customer_first_name,
                    c.last_name as customer_last_name,
                    c.phone as customer_phone,
                    s.uuid as store_uuid,
                    s.name as store_name,
                    u.uuid as seller_uuid,
                    u.first_name as seller_first_name,
                    u.last_name as seller_last_name,
                    u.email as seller_email,
                    (SELECT COUNT(*) FROM orderitems WHERE order_id = o.id) as item_count
                FROM orders o
                LEFT JOIN customers c ON o.customer_id = c.id
                LEFT JOIN stores s ON o.store_id = s.id
                LEFT JOIN users u ON s.user_id = u.id
            ]] .. where_clause .. [[
                ORDER BY ]] .. order_field .. " " .. order_dir .. [[
                LIMIT ]] .. per_page .. [[ OFFSET ]] .. offset

            local orders = db.query(orders_query)

            -- Parse JSON fields and structure response
            local orders_list = {}
            for _, order in ipairs(orders or {}) do
                -- Parse billing_address
                if order.billing_address and order.billing_address ~= "" then
                    local ok, parsed = pcall(cjson.decode, order.billing_address)
                    if ok then order.billing_address = parsed end
                end

                -- Parse shipping_address
                if order.shipping_address and order.shipping_address ~= "" then
                    local ok, parsed = pcall(cjson.decode, order.shipping_address)
                    if ok then order.shipping_address = parsed end
                end

                -- Structure customer info
                order.customer = {
                    uuid = order.customer_uuid,
                    email = order.customer_email,
                    first_name = order.customer_first_name,
                    last_name = order.customer_last_name,
                    phone = order.customer_phone,
                    full_name = (order.customer_first_name or "") .. " " .. (order.customer_last_name or "")
                }

                -- Structure store info
                order.store = {
                    uuid = order.store_uuid,
                    name = order.store_name
                }

                -- Structure seller info (only for admin)
                if user_role == "administrative" then
                    order.seller = {
                        uuid = order.seller_uuid,
                        first_name = order.seller_first_name,
                        last_name = order.seller_last_name,
                        email = order.seller_email,
                        full_name = (order.seller_first_name or "") .. " " .. (order.seller_last_name or "")
                    }
                end

                -- Clean up flat fields
                order.customer_uuid = nil
                order.customer_email = nil
                order.customer_first_name = nil
                order.customer_last_name = nil
                order.customer_phone = nil
                order.store_uuid = nil
                order.store_name = nil
                order.seller_uuid = nil
                order.seller_first_name = nil
                order.seller_last_name = nil
                order.seller_email = nil

                table.insert(orders_list, order)
            end

            -- Calculate pagination metadata
            local total_pages = math.ceil(total / per_page)

            return {
                json = {
                    data = orders_list,
                    total = total,
                    page = page,
                    per_page = per_page,
                    total_pages = total_pages,
                    has_next = page < total_pages,
                    has_prev = page > 1,
                    user_role = user_role
                }
            }
        end),

        POST = AuthMiddleware.requireAuth(function(self)
            local timestamp = require("helper.global").getCurrentTimestamp()
            self.params.created_at = timestamp
            self.params.updated_at = timestamp
            return { json = OrderQueries.create(self.params), status = 201 }
        end)
    }))

    -- Get order statistics for dashboard (MUST be before :id route)
    app:match("order_stats", "/api/v2/orders/stats", respond_to({
        GET = AuthMiddleware.requireAuth(function(self)
            local user_role = getUserRole(self.current_user.uuid)
            local user_stores = getUserStores(self.current_user.uuid)

            local where_clause = ""
            if user_role ~= "administrative" then
                if #user_stores > 0 then
                    local store_ids = {}
                    for _, store in ipairs(user_stores) do
                        table.insert(store_ids, store.id)
                    end
                    where_clause = "WHERE store_id IN (" .. table.concat(store_ids, ",") .. ")"
                else
                    return {
                        json = {
                            total_orders = 0,
                            pending_orders = 0,
                            processing_orders = 0,
                            delivered_orders = 0,
                            total_revenue = 0
                        }
                    }
                end
            end

            local stats = db.query([[
                SELECT
                    COUNT(*) as total_orders,
                    COUNT(CASE WHEN status = 'pending' THEN 1 END) as pending_orders,
                    COUNT(CASE WHEN status IN ('confirmed', 'processing') THEN 1 END) as processing_orders,
                    COUNT(CASE WHEN status = 'delivered' THEN 1 END) as delivered_orders,
                    COUNT(CASE WHEN status = 'cancelled' THEN 1 END) as cancelled_orders,
                    COALESCE(SUM(CASE WHEN status != 'cancelled' THEN total_amount ELSE 0 END), 0) as total_revenue,
                    COALESCE(SUM(CASE WHEN status = 'pending' THEN total_amount ELSE 0 END), 0) as pending_revenue
                FROM orders
            ]] .. where_clause)

            return {
                json = stats and stats[1] or {
                    total_orders = 0,
                    pending_orders = 0,
                    processing_orders = 0,
                    delivered_orders = 0,
                    total_revenue = 0
                }
            }
        end)
    }))

    -- Get all stores for filter dropdown (MUST be before :id route)
    app:match("orders_stores", "/api/v2/orders/stores", respond_to({
        GET = AuthMiddleware.requireAuth(function(self)
            local user_role = getUserRole(self.current_user.uuid)
            local user_stores = getUserStores(self.current_user.uuid)

            local stores
            if user_role == "administrative" then
                -- Admin sees all stores
                stores = db.query([[
                    SELECT s.uuid, s.name, u.first_name || ' ' || u.last_name as owner_name
                    FROM stores s
                    LEFT JOIN users u ON s.user_id = u.id
                    ORDER BY s.name
                ]])
            else
                -- Seller sees only their stores
                stores = user_stores
            end

            return { json = { data = stores or {} } }
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
                local user_role = getUserRole(self.current_user.uuid)
                if user_role ~= "administrative" then
                    return { json = { error = "Access denied - not your store" }, status = 403 }
                end
            end

            -- Pagination
            local page = tonumber(self.params.page) or 1
            local per_page = tonumber(self.params.per_page) or 10
            local offset = (page - 1) * per_page

            -- Get total count
            local count_result = db.query([[
                SELECT COUNT(*) as total
                FROM orders o
                JOIN stores s ON o.store_id = s.id
                WHERE s.uuid = ?
            ]], store_id)
            local total = count_result and count_result[1] and count_result[1].total or 0

            -- Get orders for this store with order items
            local orders = db.query([[
                SELECT o.*,
                       c.email as customer_email,
                       c.first_name as customer_first_name,
                       c.last_name as customer_last_name,
                       s.name as store_name,
                       (SELECT COUNT(*) FROM orderitems WHERE order_id = o.id) as item_count
                FROM orders o
                LEFT JOIN customers c ON o.customer_id = c.id
                LEFT JOIN stores s ON o.store_id = s.id
                WHERE s.uuid = ?
                ORDER BY o.created_at DESC
                LIMIT ? OFFSET ?
            ]], store_id, per_page, offset)

            -- Process orders
            for _, order in ipairs(orders or {}) do
                -- Parse JSON fields
                if order.billing_address then
                    local success, parsed = pcall(cjson.decode, order.billing_address)
                    if success then order.billing_address = parsed end
                end
                if order.shipping_address then
                    local success, parsed = pcall(cjson.decode, order.shipping_address)
                    if success then order.shipping_address = parsed end
                end
            end

            local total_pages = math.ceil(total / per_page)

            return {
                json = {
                    data = orders or {},
                    total = total,
                    page = page,
                    per_page = per_page,
                    total_pages = total_pages
                }
            }
        end)
    }))

    -- Get single order with details (includes delivery partner info)
    app:match("order_details", "/api/v2/orders/:id", respond_to({
        GET = AuthMiddleware.requireAuth(function(self)
            local order_id = self.params.id
            local user_role = getUserRole(self.current_user.uuid)
            local user_stores = getUserStores(self.current_user.uuid)

            -- Get order with store and delivery partner info
            local orders = db.query([[
                SELECT o.*,
                       c.uuid as customer_uuid,
                       c.email as customer_email,
                       c.first_name as customer_first_name,
                       c.last_name as customer_last_name,
                       c.phone as customer_phone,
                       c.addresses as customer_addresses,
                       s.name as store_name,
                       s.uuid as store_uuid,
                       s.user_id as store_owner_id,
                       u.uuid as seller_uuid,
                       u.first_name as seller_first_name,
                       u.last_name as seller_last_name,
                       u.email as seller_email,
                       dp.id as dp_id,
                       dp.uuid as dp_uuid,
                       dp.company_name as dp_company_name,
                       dp.contact_person_name as dp_contact_person_name,
                       dp.contact_person_phone as dp_contact_person_phone,
                       dp.rating as dp_rating,
                       dp.total_deliveries as dp_total_deliveries,
                       dp.service_type as dp_service_type,
                       dp.vehicle_types as dp_vehicle_types,
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
                LEFT JOIN users u ON s.user_id = u.id
                LEFT JOIN delivery_partners dp ON o.delivery_partner_id = dp.id
                LEFT JOIN order_delivery_assignments oda ON o.id = oda.order_id
                WHERE o.uuid = ?
            ]], order_id)

            if not orders or #orders == 0 then
                return { json = { error = "Order not found" }, status = 404 }
            end

            local order = orders[1]

            -- Access control: admin can see all, seller can only see their store orders
            if user_role ~= "administrative" then
                local has_access = false
                for _, store in ipairs(user_stores) do
                    if store.id == order.store_id then
                        has_access = true
                        break
                    end
                end
                if not has_access then
                    return { json = { error = "Access denied" }, status = 403 }
                end
            end

            -- Get order items with product details
            local items = db.query([[
                SELECT
                    oi.id,
                    oi.uuid,
                    oi.quantity,
                    oi.price,
                    oi.total,
                    oi.product_title,
                    oi.variant_title,
                    oi.sku,
                    oi.created_at,
                    sp.uuid as product_uuid,
                    sp.name as product_name,
                    sp.images as product_images
                FROM orderitems oi
                LEFT JOIN storeproducts sp ON oi.product_id = sp.id
                WHERE oi.order_id = ?
                ORDER BY oi.id
            ]], order.id)

            -- Process items
            for _, item in ipairs(items or {}) do
                if item.product_images then
                    local ok, parsed = pcall(cjson.decode, item.product_images)
                    if ok then item.product_images = parsed end
                end
            end
            order.items = items or {}

            -- Get order history
            local history = db.query([[
                SELECT
                    id, uuid, action, previous_status, new_status,
                    notes, tracking_number, tracking_url, created_at
                FROM order_history
                WHERE order_id = ?
                ORDER BY created_at DESC
            ]], order.id)
            order.history = history or {}

            -- Parse JSON fields
            if order.billing_address then
                local ok, parsed = pcall(cjson.decode, order.billing_address)
                if ok then order.billing_address = parsed end
            end
            if order.shipping_address then
                local ok, parsed = pcall(cjson.decode, order.shipping_address)
                if ok then order.shipping_address = parsed end
            end
            if order.customer_addresses then
                local ok, parsed = pcall(cjson.decode, order.customer_addresses)
                if ok then order.customer_addresses = parsed end
            end

            -- Structure customer info
            order.customer = {
                uuid = order.customer_uuid,
                email = order.customer_email,
                first_name = order.customer_first_name,
                last_name = order.customer_last_name,
                phone = order.customer_phone,
                addresses = order.customer_addresses,
                full_name = (order.customer_first_name or "") .. " " .. (order.customer_last_name or "")
            }

            -- Structure store info
            order.store = {
                uuid = order.store_uuid,
                name = order.store_name
            }

            -- Structure seller info (for admin)
            if user_role == "administrative" then
                order.seller = {
                    uuid = order.seller_uuid,
                    first_name = order.seller_first_name,
                    last_name = order.seller_last_name,
                    email = order.seller_email,
                    full_name = (order.seller_first_name or "") .. " " .. (order.seller_last_name or "")
                }
            end

            -- Structure delivery partner info
            if order.dp_id then
                local vehicle_types = {}
                if order.dp_vehicle_types and order.dp_vehicle_types ~= "" then
                    local ok, parsed = pcall(cjson.decode, order.dp_vehicle_types)
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
            end

            -- Clean up flat fields
            local fields_to_remove = {
                "customer_uuid", "customer_email", "customer_first_name", "customer_last_name",
                "customer_phone", "customer_addresses", "store_uuid", "store_name", "store_owner_id",
                "seller_uuid", "seller_first_name", "seller_last_name", "seller_email",
                "dp_id", "dp_uuid", "dp_company_name", "dp_contact_person_name",
                "dp_contact_person_phone", "dp_rating", "dp_total_deliveries",
                "dp_service_type", "dp_vehicle_types", "assignment_id", "assignment_uuid",
                "delivery_status", "tracking_number", "delivery_fee", "accepted_at",
                "actual_pickup_time", "estimated_delivery_time", "actual_delivery_time"
            }
            for _, field in ipairs(fields_to_remove) do
                order[field] = nil
            end

            return { json = order }
        end),

        PUT = AuthMiddleware.requireAuth(function(self)
            local order_id = self.params.id
            local user_role = getUserRole(self.current_user.uuid)
            local user_stores = getUserStores(self.current_user.uuid)

            -- Get order
            local order = db.query("SELECT * FROM orders WHERE uuid = ?", order_id)
            if not order or #order == 0 then
                return { json = { error = "Order not found" }, status = 404 }
            end
            order = order[1]

            -- Access control
            if user_role ~= "administrative" then
                local has_access = false
                for _, store in ipairs(user_stores) do
                    if store.id == order.store_id then
                        has_access = true
                        break
                    end
                end
                if not has_access then
                    return { json = { error = "Access denied" }, status = 403 }
                end
            end

            self.params.updated_at = require("helper.global").getCurrentTimestamp()
            return { json = OrderQueries.update(order_id, self.params), status = 200 }
        end),

        DELETE = AuthMiddleware.requireAuth(function(self)
            local order_id = self.params.id
            local user_role = getUserRole(self.current_user.uuid)

            -- Only admin can delete orders
            if user_role ~= "administrative" then
                return { json = { error = "Access denied - admin only" }, status = 403 }
            end

            return { json = OrderQueries.destroy(order_id), status = 200 }
        end)
    }))

    -- Update order status with validation and audit trail
    app:match("update_order_status", "/api/v2/orders/:id/status", respond_to({
        PUT = AuthMiddleware.requireAuth(function(self)
            local order_id = self.params.id
            local user_role = getUserRole(self.current_user.uuid)
            local user_stores = getUserStores(self.current_user.uuid)

            local new_status = self.params.status
            local new_financial_status = self.params.financial_status
            local new_fulfillment_status = self.params.fulfillment_status
            local notes = self.params.notes

            -- Get order
            local orders = db.query([[
                SELECT o.*, s.id as store_id_check
                FROM orders o
                LEFT JOIN stores s ON o.store_id = s.id
                WHERE o.uuid = ?
            ]], order_id)

            if not orders or #orders == 0 then
                return { json = { error = "Order not found" }, status = 404 }
            end

            local order = orders[1]

            -- Access control
            if user_role ~= "administrative" then
                local has_access = false
                for _, store in ipairs(user_stores) do
                    if store.id == order.store_id then
                        has_access = true
                        break
                    end
                end
                if not has_access then
                    return { json = { error = "Access denied" }, status = 403 }
                end
            end

            -- Validate status transitions
            local valid_statuses = {
                pending = true, confirmed = true, processing = true,
                shipped = true, delivered = true, cancelled = true, refunded = true
            }
            if new_status and not valid_statuses[new_status] then
                return { json = { error = "Invalid status: " .. new_status }, status = 400 }
            end

            -- Build update data
            local update_data = { updated_at = db.format_date() }
            local previous_status = order.status

            if new_status then update_data.status = new_status end
            if new_financial_status then update_data.financial_status = new_financial_status end
            if new_fulfillment_status then update_data.fulfillment_status = new_fulfillment_status end

            -- Update order
            db.update("orders", update_data, "uuid = ?", order_id)

            -- Create audit trail entry
            if new_status and new_status ~= previous_status then
                local Global = require("helper.global")
                db.insert("order_history", {
                    uuid = Global.generateUUID(),
                    order_id = order.id,
                    action = "status_change",
                    previous_status = previous_status,
                    new_status = new_status,
                    notes = notes,
                    created_at = db.format_date()
                })
            end

            -- Get updated order
            local updated_order = db.query("SELECT * FROM orders WHERE uuid = ?", order_id)

            return {
                json = {
                    message = "Order status updated successfully",
                    order = updated_order and updated_order[1] or nil
                }
            }
        end)
    }))

    ngx.log(ngx.NOTICE, "Orders routes initialized successfully")
end
