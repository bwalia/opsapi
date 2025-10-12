local lapis = require("lapis")
local respond_to = require("lapis.application").respond_to
local AuthMiddleware = require("middleware.auth")
local DeliveryRequestQueries = require("queries.DeliveryRequestQueries")
local OrderDeliveryAssignmentQueries = require("queries.OrderDeliveryAssignmentQueries")
local cjson = require("cjson")
local db = require("lapis.db")

return function(app)
    -- Create delivery request (either partner→seller or seller→partner)
    app:match("/api/v2/delivery-requests", respond_to({
        POST = AuthMiddleware.requireAuth(function(self)
            -- Get user ID from current_user
            local user = db.query("SELECT id FROM users WHERE uuid = ?", self.current_user.uuid)[1]
            if not user then
                return { status = 404, json = { error = "User not found" } }
            end
            local user_id = user.id
            local params = self.params

            if not params.order_id or not params.delivery_partner_id then
                return { status = 400, json = { error = "order_id and delivery_partner_id are required" } }
            end

            if not params.request_type or (params.request_type ~= "partner_to_seller" and params.request_type ~= "seller_to_partner") then
                return { status = 400, json = { error = "request_type must be 'partner_to_seller' or 'seller_to_partner'" } }
            end

            -- Get order with store info
            local order = db.query([[
                SELECT o.*, s.user_id as store_owner_id
                FROM orders o
                INNER JOIN stores s ON o.store_id = s.id
                WHERE o.id = ?
            ]], params.order_id)[1]

            if not order then
                return { status = 404, json = { error = "Order not found" } }
            end

            -- Get delivery partner info
            local delivery_partner = db.query("SELECT * FROM delivery_partners WHERE id = ?", params.delivery_partner_id)[1]
            if not delivery_partner then
                return { status = 404, json = { error = "Delivery partner not found" } }
            end

            -- Verify requester
            if params.request_type == "partner_to_seller" then
                -- Partner is requesting, verify they are the partner
                if delivery_partner.user_id ~= user_id then
                    return { status = 403, json = { error = "You don't have permission to create this request" } }
                end
            elseif params.request_type == "seller_to_partner" then
                -- Seller is requesting, verify they own the store
                if order.store_owner_id ~= user_id then
                    return { status = 403, json = { error = "You don't have permission to create this request" } }
                end
            end

            -- Check if order already has an assignment
            local existing_assignment = db.query("SELECT * FROM order_delivery_assignments WHERE order_id = ?", params.order_id)[1]
            if existing_assignment then
                return { status = 400, json = { error = "Order already has a delivery assignment" } }
            end

            -- Check if request already exists
            local existing_request = db.query([[
                SELECT * FROM delivery_requests
                WHERE order_id = ? AND delivery_partner_id = ? AND status = 'pending'
            ]], params.order_id, params.delivery_partner_id)[1]

            if existing_request then
                return { status = 400, json = { error = "A pending request already exists for this order and partner" } }
            end

            -- Create request
            local success, request = pcall(function()
                return DeliveryRequestQueries.create({
                    order_id = params.order_id,
                    delivery_partner_id = params.delivery_partner_id,
                    request_type = params.request_type,
                    proposed_fee = params.proposed_fee or 0,
                    message = params.message,
                    expires_at = params.expires_at  -- Optional, will default to 24h
                })
            end)

            if not success then
                ngx.log(ngx.ERR, "Failed to create delivery request: " .. tostring(request))
                return { status = 500, json = { error = "Failed to create delivery request" } }
            end

            return { json = {
                message = "Delivery request created successfully",
                request = request
            }}
        end)
    }))

    -- Get delivery requests for delivery partner
    app:match("/api/v2/delivery-requests/partner", respond_to({
        GET = AuthMiddleware.requireAuth(function(self)
            -- Get user ID from current_user
            local user = db.query("SELECT id FROM users WHERE uuid = ?", self.current_user.uuid)[1]
            if not user then
                return { status = 404, json = { error = "User not found" } }
            end
            local user_id = user.id
            local status = self.params.status

            -- Get delivery partner ID
            local delivery_partner = db.query("SELECT * FROM delivery_partners WHERE user_id = ?", user_id)[1]
            if not delivery_partner then
                return { status = 404, json = { error = "Delivery partner profile not found" } }
            end

            -- Expire old requests first
            pcall(function()
                DeliveryRequestQueries.expireOldRequests()
            end)

            local success, requests = pcall(function()
                return DeliveryRequestQueries.getByDeliveryPartner(delivery_partner.id, status)
            end)

            if not success then
                ngx.log(ngx.ERR, "Failed to get requests: " .. tostring(requests))
                return { status = 500, json = { error = "Failed to fetch requests" } }
            end

            return { json = { requests = requests or {} } }
        end)
    }))

    -- Get delivery requests for store
    app:match("/api/v2/delivery-requests/store/:store_slug", respond_to({
        GET = AuthMiddleware.requireAuth(function(self)
            -- Get user ID from current_user
            local user = db.query("SELECT id FROM users WHERE uuid = ?", self.current_user.uuid)[1]
            if not user then
                return { status = 404, json = { error = "User not found" } }
            end
            local user_id = user.id
            local store_slug = self.params.store_slug
            local status = self.params.status

            -- Verify store ownership
            local store = db.query("SELECT * FROM stores WHERE slug = ?", store_slug)[1]
            if not store then
                return { status = 404, json = { error = "Store not found" } }
            end

            if store.user_id ~= user_id then
                return { status = 403, json = { error = "You don't have permission to view these requests" } }
            end

            -- Expire old requests first
            pcall(function()
                DeliveryRequestQueries.expireOldRequests()
            end)

            local success, requests = pcall(function()
                return DeliveryRequestQueries.getByStore(store.id, status)
            end)

            if not success then
                ngx.log(ngx.ERR, "Failed to get requests: " .. tostring(requests))
                return { status = 500, json = { error = "Failed to fetch requests" } }
            end

            return { json = { requests = requests or {} } }
        end)
    }))

    -- Accept delivery request
    app:match("/api/v2/delivery-requests/:uuid/accept", respond_to({
        PUT = AuthMiddleware.requireAuth(function(self)
            local uuid = self.params.uuid
            -- Get user ID from current_user
            local user = db.query("SELECT id FROM users WHERE uuid = ?", self.current_user.uuid)[1]
            if not user then
                return { status = 404, json = { error = "User not found" } }
            end
            local user_id = user.id

            -- Get request
            local request = db.query("SELECT * FROM delivery_requests WHERE uuid = ?", uuid)[1]
            if not request then
                return { status = 404, json = { error = "Request not found" } }
            end

            if request.status ~= "pending" then
                return { status = 400, json = { error = "Request is not pending" } }
            end

            -- Check if expired
            if request.expires_at then
                local expires_at = ngx.parse_http_time(request.expires_at)
                if expires_at and expires_at < ngx.time() then
                    -- Mark as expired
                    db.update("delivery_requests", {
                        status = "expired",
                        updated_at = db.format_date()
                    }, "id = ?", request.id)
                    return { status = 400, json = { error = "Request has expired" } }
                end
            end

            -- Get order with store info
            local order = db.query([[
                SELECT o.*, s.user_id as store_owner_id
                FROM orders o
                INNER JOIN stores s ON o.store_id = s.id
                WHERE o.id = ?
            ]], request.order_id)[1]

            if not order then
                return { status = 404, json = { error = "Order not found" } }
            end

            -- Get delivery partner info
            local delivery_partner = db.query("SELECT * FROM delivery_partners WHERE id = ?", request.delivery_partner_id)[1]
            if not delivery_partner then
                return { status = 404, json = { error = "Delivery partner not found" } }
            end

            -- Verify the accepter based on request type
            if request.request_type == "partner_to_seller" then
                -- Seller needs to accept
                if order.store_owner_id ~= user_id then
                    return { status = 403, json = { error = "Only the store owner can accept this request" } }
                end
            elseif request.request_type == "seller_to_partner" then
                -- Partner needs to accept
                if delivery_partner.user_id ~= user_id then
                    return { status = 403, json = { error = "Only the delivery partner can accept this request" } }
                end
            end

            -- Check if order already has an assignment
            local existing_assignment = db.query("SELECT * FROM order_delivery_assignments WHERE order_id = ?", request.order_id)[1]
            if existing_assignment then
                return { status = 400, json = { error = "Order already has a delivery assignment" } }
            end

            -- Check partner capacity
            if delivery_partner.current_active_orders >= delivery_partner.max_daily_capacity then
                return { status = 400, json = { error = "Delivery partner is at full capacity" } }
            end

            -- Accept request
            local success, updated_request = pcall(function()
                return DeliveryRequestQueries.accept(request.id, self.params.response_message)
            end)

            if not success then
                ngx.log(ngx.ERR, "Failed to accept request: " .. tostring(updated_request))
                return { status = 500, json = { error = "Failed to accept request" } }
            end

            -- Create delivery assignment
            local assignment_success, assignment = pcall(function()
                return OrderDeliveryAssignmentQueries.create({
                    order_id = request.order_id,
                    delivery_partner_id = request.delivery_partner_id,
                    assignment_type = request.request_type,
                    delivery_fee = request.proposed_fee,
                    pickup_address = order.shipping_address or "",
                    delivery_address = order.shipping_address or "",
                    status = "pending"
                })
            end)

            if not assignment_success then
                ngx.log(ngx.ERR, "Failed to create assignment: " .. tostring(assignment))
                return { status = 500, json = { error = "Failed to create delivery assignment" } }
            end

            -- Update order with delivery partner
            db.update("orders", {
                delivery_partner_id = request.delivery_partner_id,
                updated_at = db.format_date()
            }, "id = ?", request.order_id)

            -- Increment partner's active orders
            db.update("delivery_partners", {
                current_active_orders = db.raw("current_active_orders + 1")
            }, "id = ?", request.delivery_partner_id)

            -- Reject all other pending requests for this order
            db.query([[
                UPDATE delivery_requests
                SET status = 'rejected',
                    response_message = 'Order already assigned to another partner',
                    responded_at = ?,
                    updated_at = ?
                WHERE order_id = ? AND id != ? AND status = 'pending'
            ]], db.format_date(), db.format_date(), request.order_id, request.id)

            return { json = {
                message = "Request accepted successfully",
                request = updated_request,
                assignment = assignment
            }}
        end)
    }))

    -- Reject delivery request
    app:match("/api/v2/delivery-requests/:uuid/reject", respond_to({
        PUT = AuthMiddleware.requireAuth(function(self)
            local uuid = self.params.uuid
            -- Get user ID from current_user
            local user = db.query("SELECT id FROM users WHERE uuid = ?", self.current_user.uuid)[1]
            if not user then
                return { status = 404, json = { error = "User not found" } }
            end
            local user_id = user.id

            -- Get request
            local request = db.query("SELECT * FROM delivery_requests WHERE uuid = ?", uuid)[1]
            if not request then
                return { status = 404, json = { error = "Request not found" } }
            end

            if request.status ~= "pending" then
                return { status = 400, json = { error = "Request is not pending" } }
            end

            -- Get order with store info
            local order = db.query([[
                SELECT o.*, s.user_id as store_owner_id
                FROM orders o
                INNER JOIN stores s ON o.store_id = s.id
                WHERE o.id = ?
            ]], request.order_id)[1]

            if not order then
                return { status = 404, json = { error = "Order not found" } }
            end

            -- Get delivery partner info
            local delivery_partner = db.query("SELECT * FROM delivery_partners WHERE id = ?", request.delivery_partner_id)[1]
            if not delivery_partner then
                return { status = 404, json = { error = "Delivery partner not found" } }
            end

            -- Verify the rejecter based on request type
            if request.request_type == "partner_to_seller" then
                -- Seller needs to reject
                if order.store_owner_id ~= user_id then
                    return { status = 403, json = { error = "Only the store owner can reject this request" } }
                end
            elseif request.request_type == "seller_to_partner" then
                -- Partner needs to reject
                if delivery_partner.user_id ~= user_id then
                    return { status = 403, json = { error = "Only the delivery partner can reject this request" } }
                end
            end

            -- Reject request
            local success, updated_request = pcall(function()
                return DeliveryRequestQueries.reject(request.id, self.params.response_message)
            end)

            if not success then
                ngx.log(ngx.ERR, "Failed to reject request: " .. tostring(updated_request))
                return { status = 500, json = { error = "Failed to reject request" } }
            end

            return { json = {
                message = "Request rejected successfully",
                request = updated_request
            }}
        end)
    }))
end
