--[[
    Order-Delivery Integration Module

    Handles automatic integration between order placement and delivery partner notifications.
    This module should be called whenever:
    - A new order is created
    - Order status changes to 'confirmed' or 'ready_for_pickup'
    - Order delivery address is updated

    Author: Senior Backend Engineer
    Date: 2025-01-19
]]--

local db = require("lapis.db")
local cjson = require("cjson")
local DeliveryNotificationService = require("lib.delivery-notification-service")

local OrderDeliveryIntegration = {}

--[[
    Extract Coordinates from Address

    Attempts to extract latitude/longitude from various address formats.
    Supports both direct coordinates and JSON address objects.

    @param address mixed - Address string or table
    @return table|nil - {latitude, longitude} or nil
]]--
local function extractCoordinates(address)
    if not address then
        return nil
    end

    -- If address is a table
    if type(address) == "table" then
        local lat = address.latitude or address.lat
        local lng = address.longitude or address.lng or address.lon

        if lat and lng then
            return {
                latitude = tonumber(lat),
                longitude = tonumber(lng),
                city = address.city,
                state = address.state,
                postal_code = address.postal_code or address.zip
            }
        end
    end

    -- If address is a JSON string
    if type(address) == "string" then
        local ok, parsed = pcall(cjson.decode, address)
        if ok and type(parsed) == "table" then
            return extractCoordinates(parsed)
        end
    end

    return nil
end

--[[
    Update Order Location Coordinates

    Updates the order table with delivery coordinates for geospatial queries.

    @param order_id integer - The order ID
    @param delivery_address table - Delivery address with coordinates
    @param pickup_address table - Pickup address with coordinates (optional)
    @return boolean - Success status
]]--
function OrderDeliveryIntegration.updateOrderLocation(order_id, delivery_address, pickup_address)
    local delivery_coords = extractCoordinates(delivery_address)
    local pickup_coords = pickup_address and extractCoordinates(pickup_address) or nil

    if not delivery_coords then
        ngx.log(ngx.WARN, "No delivery coordinates provided for order " .. order_id)
        return false
    end

    local success = pcall(function()
        local updates = {
            delivery_latitude = delivery_coords.latitude,
            delivery_longitude = delivery_coords.longitude,
            updated_at = db.format_date()
        }

        if pickup_coords then
            updates.pickup_latitude = pickup_coords.latitude
            updates.pickup_longitude = pickup_coords.longitude
        end

        db.update("orders", updates, "id = ?", order_id)

        ngx.log(ngx.INFO, string.format(
            "Updated location for order %d: delivery(%.6f, %.6f)",
            order_id,
            delivery_coords.latitude,
            delivery_coords.longitude
        ))
    end)

    return success
end

--[[
    Process New Order for Delivery Partner Notifications

    Main integration point called when a new order is created or confirmed.
    This function:
    1. Updates order location coordinates
    2. Finds nearby delivery partners
    3. Creates notifications for eligible partners
    4. Logs the entire process

    @param order_id integer - The order ID
    @param order_data table - Order information including addresses
    @return table - Result with notification count and partner list
]]--
function OrderDeliveryIntegration.processNewOrder(order_id, order_data)
    ngx.log(ngx.INFO, "=== PROCESSING ORDER FOR DELIVERY INTEGRATION: " .. order_id .. " ===")

    -- Extract delivery address
    local delivery_address = order_data.shipping_address or order_data.delivery_address
    if not delivery_address then
        ngx.log(ngx.WARN, "Order " .. order_id .. " has no delivery address")
        return {
            success = false,
            error = "No delivery address provided"
        }
    end

    -- Parse address if it's a string
    if type(delivery_address) == "string" then
        local ok, parsed = pcall(cjson.decode, delivery_address)
        if ok then
            delivery_address = parsed
        end
    end

    -- Update order location in database
    local location_updated = OrderDeliveryIntegration.updateOrderLocation(
        order_id,
        delivery_address,
        order_data.pickup_address
    )

    if not location_updated then
        ngx.log(ngx.WARN, "Failed to update location for order " .. order_id)
        -- Continue anyway - we can still notify using address text
    end

    -- Check if store has can_self_ship enabled
    if order_data.store_id then
        local store = db.query("SELECT can_self_ship FROM stores WHERE id = ?", order_data.store_id)[1]
        if store and store.can_self_ship == false then
            -- Store requires delivery partner
            ngx.log(ngx.INFO, "Store requires delivery partner for order " .. order_id)
        end
    end

    -- Prepare order info for notifications
    local order_info = {
        order_id = order_id,
        order_number = order_data.order_number,
        total_amount = order_data.total_amount,
        status = order_data.status,
        store_id = order_data.store_id,
        max_search_distance_km = order_data.max_search_distance_km or 50
    }

    -- Notify delivery partners
    local notification_result = DeliveryNotificationService.notifyPartnersAboutOrder(
        order_id,
        delivery_address,
        order_info
    )

    return notification_result
end

--[[
    Handle Order Status Change

    Called when order status changes to determine if delivery partners should be notified.

    @param order_id integer - The order ID
    @param old_status string - Previous order status
    @param new_status string - New order status
    @param order_data table - Full order information
    @return table|nil - Notification result or nil if no notification needed
]]--
function OrderDeliveryIntegration.handleOrderStatusChange(order_id, old_status, new_status, order_data)
    -- Notify partners when order becomes ready for pickup
    local notify_statuses = {
        confirmed = true,
        ready_for_pickup = true,
        packing = true
    }

    if not notify_statuses[new_status] then
        return nil
    end

    -- Check if already has delivery assignment
    local has_assignment = db.query(
        "SELECT id FROM order_delivery_assignments WHERE order_id = ?",
        order_id
    )[1]

    if has_assignment then
        ngx.log(ngx.INFO, "Order " .. order_id .. " already has delivery assignment")
        return nil
    end

    ngx.log(ngx.INFO, string.format(
        "Order %d status changed to %s, notifying delivery partners",
        order_id,
        new_status
    ))

    return OrderDeliveryIntegration.processNewOrder(order_id, order_data)
end

--[[
    Get Delivery Partner Recommendations for Order

    Returns a ranked list of delivery partners for a specific order.
    Used by sellers to choose a delivery partner.

    @param order_id integer - The order ID
    @param limit integer - Maximum number of partners to return (default: 10)
    @return table - Array of recommended delivery partners
]]--
function OrderDeliveryIntegration.getRecommendedPartners(order_id, limit)
    limit = limit or 10

    local order = db.query([[
        SELECT
            o.*,
            s.name as store_name,
            s.address as store_address
        FROM orders o
        INNER JOIN stores s ON o.store_id = s.id
        WHERE o.id = ?
    ]], order_id)[1]

    if not order then
        return {}
    end

    if not order.delivery_latitude or not order.delivery_longitude then
        ngx.log(ngx.WARN, "Order " .. order_id .. " has no delivery coordinates")
        return {}
    end

    -- Find partners using PostGIS function
    local partners = db.query([[
        SELECT
            *,
            calculate_delivery_fee(id, distance_km, ?) as calculated_fee
        FROM find_nearby_delivery_partners(?, ?, 50)
        ORDER BY distance_km ASC, rating DESC
        LIMIT ?
    ]],
    order.total_amount,
    order.delivery_latitude,
    order.delivery_longitude,
    limit
    )

    return partners or {}
end

--[[
    Auto-Assign Best Delivery Partner

    Automatically assigns the best available delivery partner to an order.
    Criteria:
    - Closest distance
    - Highest rating
    - Available capacity

    @param order_id integer - The order ID
    @return table - Assignment result
]]--
function OrderDeliveryIntegration.autoAssignBestPartner(order_id)
    local partners = OrderDeliveryIntegration.getRecommendedPartners(order_id, 1)

    if not partners or #partners == 0 then
        return {
            success = false,
            error = "No eligible delivery partners found"
        }
    end

    local best_partner = partners[1]

    -- Create assignment
    local Global = require("helper.global")
    local OrderDeliveryAssignmentQueries = require("queries.OrderDeliveryAssignmentQueries")

    local order = db.query("SELECT * FROM orders WHERE id = ?", order_id)[1]

    local success, assignment = pcall(function()
        return OrderDeliveryAssignmentQueries.create({
            order_id = order_id,
            delivery_partner_id = best_partner.id,
            assignment_type = "auto_assigned",
            delivery_fee = best_partner.calculated_fee,
            pickup_address = order.billing_address, -- or store address
            delivery_address = order.shipping_address,
            distance_km = best_partner.distance_km
        })
    end)

    if not success then
        ngx.log(ngx.ERR, "Failed to create auto-assignment: " .. tostring(assignment))
        return {
            success = false,
            error = "Failed to create assignment"
        }
    end

    -- Update order
    db.update("orders", {
        delivery_partner_id = best_partner.id,
        updated_at = db.format_date()
    }, "id = ?", order_id)

    -- Increment partner's active orders
    db.update("delivery_partners", {
        current_active_orders = db.raw("current_active_orders + 1")
    }, "id = ?", best_partner.id)

    ngx.log(ngx.INFO, string.format(
        "Auto-assigned order %d to partner %s (%.2f km away, fee: ₹%.2f)",
        order_id,
        best_partner.company_name,
        best_partner.distance_km,
        best_partner.calculated_fee
    ))

    return {
        success = true,
        assignment = assignment,
        partner = best_partner
    }
end

return OrderDeliveryIntegration
