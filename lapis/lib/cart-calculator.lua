-- Professional Cart Calculation Library
-- Handles dynamic tax and shipping calculations based on store settings

local db = require("lapis.db")
local StoreModel = require "models.StoreModel"

local CartCalculator = {}

-- Calculate totals for a cart with dynamic tax and shipping
function CartCalculator.calculateTotals(cart_items)
    if not cart_items or #cart_items == 0 then
        return {
            subtotal = 0,
            tax_amount = 0,
            shipping_amount = 0,
            total_amount = 0,
            store_totals = {}
        }
    end

    local store_totals = {}
    local subtotal = 0
    local requires_shipping = false

    -- Group items by store and calculate subtotals
    for _, item in ipairs(cart_items) do
        local store_id = item.store_id

        if not store_totals[store_id] then
            store_totals[store_id] = {
                subtotal = 0,
                tax_amount = 0,
                shipping_amount = 0,
                items = {},
                store_info = nil
            }
        end

        local item_total = tonumber(item.price) * tonumber(item.quantity)
        store_totals[store_id].subtotal = store_totals[store_id].subtotal + item_total
        subtotal = subtotal + item_total

        table.insert(store_totals[store_id].items, item)

        -- Check if any item requires shipping
        if item.requires_shipping then
            requires_shipping = true
        end
    end

    -- Calculate tax and shipping for each store
    local total_tax = 0
    local total_shipping = 0

    for store_id, store_data in pairs(store_totals) do
        -- Get store information for tax and shipping settings
        local store = StoreModel:find({ id = store_id })
        if store then
            -- Include only necessary store info to avoid serialization issues
            store_data.store_info = {
                id = store.id,
                uuid = store.uuid,
                name = store.name,
                slug = store.slug,
                tax_rate = tonumber(store.tax_rate) or 0,
                shipping_enabled = store.shipping_enabled,
                shipping_flat_rate = tonumber(store.shipping_flat_rate) or 0,
                free_shipping_threshold = tonumber(store.free_shipping_threshold) or 0
            }

            -- Calculate tax based on store's tax rate
            local tax_rate = tonumber(store.tax_rate) or 0
            store_data.tax_amount = store_data.subtotal * tax_rate
            total_tax = total_tax + store_data.tax_amount

            -- Calculate shipping if store has shipping enabled and items require shipping
            if store.shipping_enabled and requires_shipping then
                local shipping_rate = tonumber(store.shipping_flat_rate) or 0
                local free_threshold = tonumber(store.free_shipping_threshold) or 0

                if free_threshold > 0 and store_data.subtotal >= free_threshold then
                    store_data.shipping_amount = 0  -- Free shipping
                else
                    store_data.shipping_amount = shipping_rate
                end

                total_shipping = total_shipping + store_data.shipping_amount
            else
                store_data.shipping_amount = 0
            end
        end
    end

    return {
        subtotal = subtotal,
        tax_amount = total_tax,
        shipping_amount = total_shipping,
        total_amount = subtotal + total_tax + total_shipping,
        store_totals = store_totals,
        requires_shipping = requires_shipping
    }
end

-- Get enhanced cart with product details for calculations
function CartCalculator.getEnhancedCart(user_id)
    local cart_items = db.select([[
        ci.*, sp.requires_shipping, sp.store_id
        FROM cart_items ci
        JOIN storeproducts sp ON ci.product_uuid = sp.uuid
        WHERE ci.user_id = ?
    ]], user_id)

    return cart_items
end

-- Calculate totals for checkout (includes store grouping for multi-store orders)
function CartCalculator.calculateCheckoutTotals(user_id)
    local enhanced_cart = CartCalculator.getEnhancedCart(user_id)
    return CartCalculator.calculateTotals(enhanced_cart)
end

return CartCalculator