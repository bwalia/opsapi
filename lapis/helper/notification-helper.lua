local db = require("lapis.db")
local Global = require("helper.global")
local cjson = require("cjson")

local NotificationHelper = {}

-- Create a notification for a user
function NotificationHelper.create(user_id, notification_type, title, message, data)
    local notification_data = {
        uuid = Global.generateUUID(),
        user_id = user_id,
        type = notification_type,
        title = title,
        message = message,
        is_read = false,
        created_at = db.format_date()
    }

    if data then
        notification_data.data = cjson.encode(data)
        if data.entity_type and data.entity_id then
            notification_data.related_entity_type = data.entity_type
            notification_data.related_entity_id = data.entity_id
        end
    end

    return db.insert("notifications", notification_data)
end

-- Notify customer about order status change
function NotificationHelper.notifyOrderStatusChange(order_id, old_status, new_status)
    -- Get order and customer info
    local orders = db.query([[
        SELECT o.*, c.user_id as customer_user_id, s.name as store_name
        FROM orders o
        LEFT JOIN customers c ON o.customer_id = c.id
        LEFT JOIN stores s ON o.store_id = s.id
        WHERE o.id = ?
    ]], order_id)

    if not orders or #orders == 0 then
        return false
    end

    local order = orders[1]
    if not order.customer_user_id then
        return false
    end

    local status_messages = {
        accepted = "Your order has been accepted by the seller",
        preparing = "Your order is being prepared",
        packing = "Your order is being packed",
        shipping = "Your order is out for delivery",
        shipped = "Your order has been shipped",
        delivered = "Your order has been delivered",
        cancelled = "Your order has been cancelled by the seller",
        refunded = "Your order has been refunded"
    }

    local title = "Order #" .. (order.order_number or order.uuid)
    local message = status_messages[new_status] or ("Order status updated to " .. new_status)

    return NotificationHelper.create(
        order.customer_user_id,
        "order_status_change",
        title,
        message,
        {
            entity_type = "order",
            entity_id = order.uuid,
            store_name = order.store_name,
            old_status = old_status,
            new_status = new_status,
            order_number = order.order_number
        }
    )
end

-- Notify seller about new order
function NotificationHelper.notifySellerNewOrder(order_id)
    local orders = db.query([[
        SELECT o.*, s.user_id as seller_user_id
        FROM orders o
        LEFT JOIN stores s ON o.store_id = s.id
        WHERE o.id = ?
    ]], order_id)

    if not orders or #orders == 0 or not orders[1].seller_user_id then
        return false
    end

    local order = orders[1]

    return NotificationHelper.create(
        order.seller_user_id,
        "new_order",
        "New Order Received",
        "You have a new order #" .. (order.order_number or order.uuid),
        {
            entity_type = "order",
            entity_id = order.uuid,
            order_number = order.order_number,
            total = order.total_price
        }
    )
end

-- Notify seller about order cancellation by customer
function NotificationHelper.notifySellerOrderCancelled(order_id)
    local orders = db.query([[
        SELECT o.*, s.user_id as seller_user_id
        FROM orders o
        LEFT JOIN stores s ON o.store_id = s.id
        WHERE o.id = ?
    ]], order_id)

    if not orders or #orders == 0 or not orders[1].seller_user_id then
        return false
    end

    local order = orders[1]

    return NotificationHelper.create(
        order.seller_user_id,
        "order_cancelled_by_customer",
        "Order Cancelled",
        "Order #" .. (order.order_number or order.uuid) .. " was cancelled by the customer",
        {
            entity_type = "order",
            entity_id = order.uuid,
            order_number = order.order_number
        }
    )
end

return NotificationHelper
