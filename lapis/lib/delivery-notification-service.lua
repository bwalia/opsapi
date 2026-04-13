--[[
    Delivery Partner Notification Service

    Professional notification system that:
    - Automatically finds delivery partners near order locations
    - Sends real-time notifications to eligible partners
    - Respects partner capacity and verification status
    - Uses geospatial queries for efficient matching

    Author: Senior Backend Engineer
    Date: 2025-01-19
]]--

local db = require("lapis.db")
local cjson = require("cjson")
local Global = require("helper.global")

local DeliveryNotificationService = {}

--[[
    Find Nearby Delivery Partners for an Order

    Uses PostGIS geospatial queries to find all delivery partners who:
    - Are within their service radius of the delivery location
    - Are verified and active
    - Have capacity for more orders
    - Service the delivery area

    @param order_id integer - The order ID
    @param delivery_lat number - Delivery location latitude
    @param delivery_lng number - Delivery location longitude
    @param max_distance_km number (optional) - Maximum search distance (default: 50km)
    @return table - Array of eligible delivery partners with distances
]]--
function DeliveryNotificationService.findNearbyPartners(order_id, delivery_lat, delivery_lng, max_distance_km)
    max_distance_km = max_distance_km or 50

    -- Validate coordinates
    if not delivery_lat or not delivery_lng then
        ngx.log(ngx.ERR, "Invalid coordinates for order " .. order_id)
        return {}
    end

    local success, partners = pcall(function()
        return db.query([[
            SELECT * FROM find_nearby_delivery_partners(?, ?, ?)
        ]], delivery_lat, delivery_lng, max_distance_km)
    end)

    if not success then
        ngx.log(ngx.ERR, "Failed to find nearby partners: " .. tostring(partners))
        return {}
    end

    return partners or {}
end

--[[
    Create Notifications for Eligible Partners

    Creates notification records for all eligible delivery partners.
    These notifications can be:
    - Displayed in the partner's dashboard
    - Sent via push notifications
    - Sent via SMS/Email

    @param order_id integer - The order ID
    @param partners table - Array of delivery partner records
    @param order_details table - Order information for notification message
    @return number - Count of notifications created
]]--
function DeliveryNotificationService.createNotifications(order_id, partners, order_details)
    if not partners or #partners == 0 then
        return 0
    end

    local notifications_created = 0
    local timestamp = Global.getCurrentTimestamp()

    for _, partner in ipairs(partners) do
        local success, result = pcall(function()
            -- Create notification title and message
            local title = "New Delivery Opportunity Nearby"
            local message = string.format(
                "A new order (₹%.2f) is available %.2f km away from your location. Delivery to %s, %s.",
                order_details.total_amount or 0,
                partner.distance_km or 0,
                order_details.city or "Unknown",
                order_details.state or "Unknown"
            )

            -- Set notification expiry (30 minutes)
            local expires_at = db.format_date(os.time() + (30 * 60))

            -- Insert notification
            db.query([[
                INSERT INTO delivery_partner_notifications (
                    uuid, delivery_partner_id, order_id,
                    notification_type, title, message,
                    distance_km, is_read, is_sent,
                    expires_at, created_at
                ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            ]],
            Global.generateStaticUUID(),
            partner.id,
            order_id,
            "new_order_nearby",
            title,
            message,
            partner.distance_km,
            false, -- is_read
            false, -- is_sent (will be sent by notification worker)
            expires_at,
            timestamp
            )

            notifications_created = notifications_created + 1
        end)

        if not success then
            ngx.log(ngx.ERR, string.format(
                "Failed to create notification for partner %d: %s",
                partner.id,
                tostring(result)
            ))
        end
    end

    ngx.log(ngx.INFO, string.format(
        "Created %d notifications for order %d",
        notifications_created,
        order_id
    ))

    return notifications_created
end

--[[
    Notify Partners About New Order

    Main entry point for notifying delivery partners about new orders.
    This function:
    1. Finds eligible delivery partners near the order location
    2. Creates notification records
    3. Logs the notification process

    Call this function when:
    - A new order is created
    - Order is confirmed and ready for pickup
    - Order status changes to 'ready_for_pickup'

    @param order_id integer - The order ID
    @param delivery_address table - Delivery address with coordinates
    @param order_info table - Additional order information
    @return table - Result with partners notified and count
]]--
function DeliveryNotificationService.notifyPartnersAboutOrder(order_id, delivery_address, order_info)
    ngx.log(ngx.INFO, "=== NOTIFYING DELIVERY PARTNERS FOR ORDER " .. order_id .. " ===")

    -- Extract coordinates from delivery address
    local delivery_lat = delivery_address.latitude or delivery_address.lat
    local delivery_lng = delivery_address.longitude or delivery_address.lng or delivery_address.lon

    if not delivery_lat or not delivery_lng then
        ngx.log(ngx.WARN, "Order " .. order_id .. " has no delivery coordinates. Cannot notify partners.")
        return {
            success = false,
            error = "No delivery coordinates provided",
            partners_notified = 0
        }
    end

    -- Find nearby delivery partners
    local partners = DeliveryNotificationService.findNearbyPartners(
        order_id,
        delivery_lat,
        delivery_lng,
        order_info.max_search_distance_km or 50
    )

    if #partners == 0 then
        ngx.log(ngx.WARN, string.format(
            "No eligible delivery partners found for order %d at (%.6f, %.6f)",
            order_id,
            delivery_lat,
            delivery_lng
        ))
        return {
            success = true,
            partners_notified = 0,
            message = "No eligible delivery partners in the area"
        }
    end

    ngx.log(ngx.INFO, string.format(
        "Found %d eligible delivery partners for order %d",
        #partners,
        order_id
    ))

    -- Prepare order details for notification message
    local order_details = {
        order_id = order_id,
        order_number = order_info.order_number,
        total_amount = order_info.total_amount,
        city = delivery_address.city,
        state = delivery_address.state,
        postal_code = delivery_address.postal_code
    }

    -- Create notifications
    local notifications_count = DeliveryNotificationService.createNotifications(
        order_id,
        partners,
        order_details
    )

    return {
        success = true,
        partners_found = #partners,
        partners_notified = notifications_count,
        partners = partners
    }
end

--[[
    Get Unread Notifications for Delivery Partner

    Fetches all unread, unexpired notifications for a delivery partner.

    @param delivery_partner_id integer - The delivery partner ID
    @return table - Array of notification records
]]--
function DeliveryNotificationService.getUnreadNotifications(delivery_partner_id)
    local success, notifications = pcall(function()
        return db.query([[
            SELECT
                n.*,
                o.order_number,
                o.total_amount,
                o.status as order_status,
                o.shipping_address,
                s.name as store_name,
                s.slug as store_slug
            FROM delivery_partner_notifications n
            INNER JOIN orders o ON n.order_id = o.id
            INNER JOIN stores s ON o.store_id = s.id
            WHERE n.delivery_partner_id = ?
            AND n.is_read = FALSE
            AND (n.expires_at IS NULL OR n.expires_at > NOW())
            AND o.status IN ('pending', 'confirmed', 'ready_for_pickup', 'packing')
            ORDER BY n.created_at DESC
            LIMIT 50
        ]], delivery_partner_id)
    end)

    if not success then
        ngx.log(ngx.ERR, "Failed to fetch notifications: " .. tostring(notifications))
        return {}
    end

    return notifications or {}
end

--[[
    Mark Notification as Read

    @param notification_id integer - The notification ID
    @param delivery_partner_id integer - The delivery partner ID (for security)
    @return boolean - Success status
]]--
function DeliveryNotificationService.markAsRead(notification_id, delivery_partner_id)
    local success = pcall(function()
        db.query([[
            UPDATE delivery_partner_notifications
            SET is_read = TRUE, read_at = NOW()
            WHERE id = ? AND delivery_partner_id = ?
        ]], notification_id, delivery_partner_id)
    end)

    return success
end

--[[
    Clean Up Expired Notifications

    Removes or marks expired notifications.
    Should be called periodically (e.g., via cron job).

    @return number - Count of expired notifications cleaned
]]--
function DeliveryNotificationService.cleanupExpiredNotifications()
    local success, result = pcall(function()
        return db.query([[
            DELETE FROM delivery_partner_notifications
            WHERE expires_at IS NOT NULL
            AND expires_at < NOW() - INTERVAL '24 hours'
        ]])
    end)

    if not success then
        ngx.log(ngx.ERR, "Failed to cleanup expired notifications: " .. tostring(result))
        return 0
    end

    ngx.log(ngx.INFO, "Cleaned up expired notifications")
    return result.affected_rows or 0
end

return DeliveryNotificationService
