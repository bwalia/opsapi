local CartModel = require "models.CartModel"
local CartItemModel = require "models.CartItemModel"
local Global = require "helper.global"

local CartQueries = {}

-- Get or create a new cart session
function CartQueries.getOrCreateSession(session_id, user_id)
    local cartSession = CartModel:find({ session_id = session_id })
    if not cartSession then
        cartSession = CartModel:create({
            session_id = session_id,
            user_id = user_id,
            expires_at = os.date("!%Y-%m-%d %H:%M:%S", os.time() + (7 * 24 * 3600)) -- 1 week expiration
        })
    end
    return cartSession
end

-- Add item to cart
function CartQueries.addItem(session_id, user_id, product_id, variant_id, quantity, price_at_time)
    local cartSession = CartQueries.getOrCreateSession(session_id, user_id)
    local cartItem = CartItemModel:find({ session_id = cartSession.session_id, product_id = product_id, variant_id = variant_id })
    if cartItem then
        cartItem:update({ quantity = cartItem.quantity + quantity })
    else
        CartItemModel:create({
            session_id = cartSession.session_id,
            user_id = user_id,
            product_id = product_id,
            variant_id = variant_id,
            quantity = quantity,
            price_at_time = price_at_time
        })
    end
    return true
end

-- Remove item from cart
function CartQueries.removeItem(session_id, product_id, variant_id)
    local cartItem = CartItemModel:find({ session_id = session_id, product_id = product_id, variant_id = variant_id })
    if cartItem then
        cartItem:delete()
        return true
    end
    return false, "Item not found"
end

-- Get cart details
function CartQueries.getCartDetails(session_id)
    local items = CartItemModel:select("*, SUM(quantity * price_at_time) as total_price WHERE session_id = ? GROUP BY id", session_id)
    local total_quantity = CartItemModel:select("SUM(quantity) as total_quantity WHERE session_id = ?", session_id)[1].total_quantity or 0
    local total_price = CartItemModel:select("SUM(quantity * price_at_time) as total_price WHERE session_id = ?", session_id)[1].total_price or 0.0
    return {
        items = items,
        total_quantity = total_quantity,
        total_price = total_price
    }
end

-- Clear cart
function CartQueries.clearCart(session_id)
    CartItemModel:delete("WHERE session_id = ?", session_id)
    return true
end

return CartQueries

