local respond_to = require("lapis.application").respond_to
local AuthMiddleware = require "middleware.auth"
local db = require("lapis.db")
local Global = require("helper.global")
local NotificationHelper = require("helper.notification-helper")

return function(app)
    -- Update Order Status (Enhanced with History Tracking)
    app:match("update_order_status_v2", "/api/v2/orders/:id/update-status", respond_to({
        PUT = AuthMiddleware.requireAuth(function(self)
            local order_uuid = self.params.id
            local new_status = self.params.status
            local notes = self.params.notes
            local tracking_number = self.params.tracking_number
            local tracking_url = self.params.tracking_url
            local carrier = self.params.carrier
            local estimated_delivery = self.params.estimated_delivery_date

            -- Valid order statuses (Professional order lifecycle)
            local valid_statuses = {
                "pending",      -- Payment pending
                "confirmed",    -- Payment confirmed, order accepted
                "processing",   -- Order being processed by seller
                "packing",      -- Order packed, ready for pickup
                "shipping",     -- Out for delivery (delivery partner picked up)
                "delivered",    -- Successfully delivered
                "cancelled",    -- Order cancelled
                "refunded"      -- Order refunded
            }

            -- Validate status
            local is_valid = false
            for _, status in ipairs(valid_statuses) do
                if status == new_status then
                    is_valid = true
                    break
                end
            end

            if not is_valid then
                return { json = { error = "Invalid status. Valid statuses: " .. table.concat(valid_statuses, ", ") }, status = 400 }
            end

            -- Get order and verify ownership
            local orders = db.query([[
                SELECT o.*, s.user_id as store_owner_id
                FROM orders o
                LEFT JOIN stores s ON o.store_id = s.id
                WHERE o.uuid = ?
            ]], order_uuid)

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

            -- Professional status transition validation
            local old_status = order.status
            local valid_transitions = {
                pending = {"confirmed", "cancelled"},       -- Payment confirmed OR cancelled
                confirmed = {"processing", "cancelled"},    -- Start processing OR cancel
                processing = {"packing", "cancelled"},      -- Mark as packed OR cancel
                packing = {"shipping", "cancelled"},        -- Delivery partner picks up (becomes shipping) OR cancel
                shipping = {"delivered", "cancelled"},      -- Delivered OR cancelled (failed delivery)
                delivered = {"refunded"},                   -- Can only refund delivered orders
                cancelled = {},                             -- Terminal state
                refunded = {}                               -- Terminal state
            }

            if old_status ~= new_status then
                local allowed = valid_transitions[old_status] or {}
                local is_allowed = false
                for _, allowed_status in ipairs(allowed) do
                    if allowed_status == new_status then
                        is_allowed = true
                        break
                    end
                end

                if not is_allowed then
                    return {
                        json = {
                            error = "Invalid status transition from '" .. old_status .. "' to '" .. new_status .. "'",
                            allowed_transitions = valid_transitions[old_status]
                        },
                        status = 400
                    }
                end
            end

            -- Build update data
            local update_data = {
                status = new_status,
                updated_at = db.format_date()
            }

            -- Update fulfillment status based on order status
            if new_status == "processing" or new_status == "packing" then
                update_data.fulfillment_status = "partial"
            elseif new_status == "shipping" or new_status == "delivered" then
                update_data.fulfillment_status = "fulfilled"
            elseif new_status == "cancelled" then
                update_data.fulfillment_status = "cancelled"
            end

            -- Add tracking information if provided
            if tracking_number then
                update_data.tracking_number = tracking_number
            end
            if tracking_url then
                update_data.tracking_url = tracking_url
            end
            if carrier then
                update_data.carrier = carrier
            end
            if estimated_delivery then
                update_data.estimated_delivery_date = estimated_delivery
            end

            -- Update order
            db.update("orders", update_data, "uuid = ?", order_uuid)

            -- Create status history record
            db.insert("order_status_history", {
                order_id = order.id,
                old_status = old_status,
                new_status = new_status,
                changed_by_user_id = user_id,
                notes = notes or nil,
                created_at = db.format_date()
            })

            -- Send notification to customer
            pcall(function()
                NotificationHelper.notifyOrderStatusChange(order.id, old_status, new_status)
            end)

            ngx.log(ngx.INFO, "Order status updated: " .. order_uuid .. " from " .. old_status .. " to " .. new_status)

            return {
                json = {
                    message = "Order status updated successfully",
                    order = {
                        uuid = order_uuid,
                        old_status = old_status,
                        new_status = new_status,
                        fulfillment_status = update_data.fulfillment_status
                    }
                },
                status = 200
            }
        end)
    }))

    -- Get Order Status History
    app:match("order_status_history", "/api/v2/orders/:id/status-history", respond_to({
        GET = AuthMiddleware.requireAuth(function(self)
            local order_uuid = self.params.id

            -- Get order and verify access
            local orders = db.query([[
                SELECT o.*, s.user_id as store_owner_id
                FROM orders o
                LEFT JOIN stores s ON o.store_id = s.id
                WHERE o.uuid = ?
            ]], order_uuid)

            if not orders or #orders == 0 then
                return { json = { error = "Order not found" }, status = 404 }
            end

            local order = orders[1]

            -- Get status history
            local history = db.query([[
                SELECT
                    osh.*,
                    u.first_name,
                    u.last_name,
                    u.email
                FROM order_status_history osh
                LEFT JOIN users u ON osh.changed_by_user_id = u.id
                WHERE osh.order_id = ?
                ORDER BY osh.created_at DESC
            ]], order.id)

            return { json = { history = history or {} }, status = 200 }
        end)
    }))

    -- Bulk Update Order Status
    app:match("bulk_update_order_status", "/api/v2/orders/bulk-update-status", respond_to({
        PUT = AuthMiddleware.requireAuth(function(self)
            local order_uuids = self.params.order_uuids  -- Array of order UUIDs
            local new_status = self.params.status
            local notes = self.params.notes

            if not order_uuids or #order_uuids == 0 then
                return { json = { error = "No orders specified" }, status = 400 }
            end

            -- Get user's stores
            local user_id_result = db.select("id from users where uuid = ?", self.current_user.uuid)
            if not user_id_result or #user_id_result == 0 then
                return { json = { error = "User not found" }, status = 404 }
            end
            local user_id = user_id_result[1].id

            local updated_count = 0
            local errors = {}

            for _, order_uuid in ipairs(order_uuids) do
                -- Get order and verify ownership
                local orders = db.query([[
                    SELECT o.*, s.user_id as store_owner_id
                    FROM orders o
                    LEFT JOIN stores s ON o.store_id = s.id
                    WHERE o.uuid = ?
                ]], order_uuid)

                if orders and #orders > 0 then
                    local order = orders[1]

                    if order.store_owner_id == user_id then
                        -- Update order
                        db.update("orders", {
                            status = new_status,
                            updated_at = db.format_date()
                        }, "uuid = ?", order_uuid)

                        -- Create history record
                        db.insert("order_status_history", {
                            order_id = order.id,
                            old_status = order.status,
                            new_status = new_status,
                            changed_by_user_id = user_id,
                            notes = notes or "Bulk update",
                            created_at = db.format_date()
                        })

                        updated_count = updated_count + 1
                    else
                        table.insert(errors, { order_uuid = order_uuid, error = "Access denied" })
                    end
                else
                    table.insert(errors, { order_uuid = order_uuid, error = "Order not found" })
                end
            end

            return {
                json = {
                    message = "Bulk update completed",
                    updated_count = updated_count,
                    errors = errors
                },
                status = 200
            }
        end)
    }))

    -- Get Available Status Transitions
    app:match("order_status_transitions", "/api/v2/orders/:id/available-transitions", respond_to({
        GET = AuthMiddleware.requireAuth(function(self)
            local order_uuid = self.params.id

            local orders = db.query([[
                SELECT o.*, s.user_id as store_owner_id
                FROM orders o
                LEFT JOIN stores s ON o.store_id = s.id
                WHERE o.uuid = ?
            ]], order_uuid)

            if not orders or #orders == 0 then
                return { json = { error = "Order not found" }, status = 404 }
            end

            local order = orders[1]
            local current_status = order.status

            local valid_transitions = {
                pending = {"confirmed", "cancelled"},
                confirmed = {"processing", "cancelled"},
                processing = {"packing", "cancelled"},
                packing = {"shipping", "cancelled"},
                shipping = {"delivered", "cancelled"},
                delivered = {"refunded"},
                cancelled = {},
                refunded = {}
            }

            return {
                json = {
                    current_status = current_status,
                    available_transitions = valid_transitions[current_status] or {}
                },
                status = 200
            }
        end)
    }))
end
