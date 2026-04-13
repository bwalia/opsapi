-- Professional Delivery Pricing System
-- Calculates fair delivery fees based on distance, order value, and configurable rules
-- Prevents exploitation by enforcing minimum and maximum fee limits

local db = require("lapis.db")

local DeliveryPricing = {}

-- Professional delivery pricing configuration
-- These can be moved to database table for admin configuration
local PRICING_CONFIG = {
    -- Base pricing (applies to all deliveries)
    base_fee = 20,              -- Base delivery fee (₹20)

    -- Distance-based pricing
    per_km_rate = 8,            -- ₹8 per kilometer
    free_delivery_radius_km = 2, -- Free delivery within 2km

    -- Distance brackets for progressive pricing
    distance_brackets = {
        { max_km = 5, rate = 8 },    -- 0-5km: ₹8/km
        { max_km = 10, rate = 10 },  -- 5-10km: ₹10/km
        { max_km = 20, rate = 12 },  -- 10-20km: ₹12/km
        { max_km = 999, rate = 15 }  -- 20km+: ₹15/km
    },

    -- Order value-based incentives
    order_value_brackets = {
        { min_value = 0, max_value = 500, fee_percentage = 0 },      -- <₹500: No percentage fee
        { min_value = 500, max_value = 1000, fee_percentage = 0 },   -- ₹500-1000: No percentage fee
        { min_value = 1000, max_value = 5000, fee_percentage = 0 },  -- ₹1000-5000: No percentage fee
        { min_value = 5000, max_value = 999999, fee_percentage = 0 } -- ₹5000+: No percentage fee
    },

    -- Fee limits (prevent exploitation)
    min_delivery_fee = 20,       -- Minimum ₹20
    max_delivery_fee = 500,      -- Maximum ₹500

    -- Partner fee limits (what partners can propose)
    partner_min_fee = 15,        -- Partners can't propose less than ₹15
    partner_max_fee = 600,       -- Partners can't propose more than ₹600
    max_deviation_percent = 30,  -- Partners can deviate max 30% from calculated fee

    -- Special pricing
    night_surcharge_percent = 20, -- 20% surcharge for night deliveries (8 PM - 6 AM)
    peak_hour_surcharge = 10,     -- ₹10 extra during peak hours (12-2 PM, 7-9 PM)

    -- Discounts
    bulk_discount_threshold = 3,  -- 3+ deliveries from same store
    bulk_discount_percent = 10,   -- 10% discount for bulk

    -- Currency
    currency = "INR"
}

-- Calculate delivery fee based on distance
function DeliveryPricing.calculateDistanceFee(distance_km)
    if not distance_km or distance_km <= 0 then
        return 0
    end

    -- Free delivery within radius
    if distance_km <= PRICING_CONFIG.free_delivery_radius_km then
        return 0
    end

    local distance_fee = 0
    local remaining_distance = distance_km

    -- Calculate using progressive brackets
    for _, bracket in ipairs(PRICING_CONFIG.distance_brackets) do
        if remaining_distance <= 0 then
            break
        end

        local bracket_distance = math.min(remaining_distance, bracket.max_km)
        distance_fee = distance_fee + (bracket_distance * bracket.rate)
        remaining_distance = remaining_distance - bracket_distance

        if remaining_distance <= 0 then
            break
        end
    end

    return distance_fee
end

-- Calculate order value-based fee (percentage)
function DeliveryPricing.calculateOrderValueFee(order_value)
    if not order_value or order_value <= 0 then
        return 0
    end

    for _, bracket in ipairs(PRICING_CONFIG.order_value_brackets) do
        if order_value >= bracket.min_value and order_value < bracket.max_value then
            return (order_value * bracket.fee_percentage) / 100
        end
    end

    return 0
end

-- Check if current time is night time (8 PM - 6 AM)
function DeliveryPricing.isNightTime()
    local hour = tonumber(os.date("%H"))
    return hour >= 20 or hour < 6
end

-- Check if current time is peak hour (12-2 PM, 7-9 PM)
function DeliveryPricing.isPeakHour()
    local hour = tonumber(os.date("%H"))
    return (hour >= 12 and hour < 14) or (hour >= 19 and hour < 21)
end

-- Professional delivery fee calculation
function DeliveryPricing.calculateDeliveryFee(params)
    local distance_km = tonumber(params.distance_km) or 0
    local order_value = tonumber(params.order_value) or 0
    local delivery_partner_id = params.delivery_partner_id
    local store_id = params.store_id

    local breakdown = {
        base_fee = PRICING_CONFIG.base_fee,
        distance_fee = 0,
        order_value_fee = 0,
        surcharges = 0,
        discounts = 0,
        partner_custom_fee = 0,
        total_fee = 0,
        currency = PRICING_CONFIG.currency,
        calculation_method = "standard"
    }

    -- 1. Calculate distance-based fee
    breakdown.distance_fee = DeliveryPricing.calculateDistanceFee(distance_km)

    -- 2. Calculate order value-based fee
    breakdown.order_value_fee = DeliveryPricing.calculateOrderValueFee(order_value)

    -- 3. Apply surcharges
    local surcharges = 0

    -- Night surcharge
    if DeliveryPricing.isNightTime() then
        surcharges = surcharges + ((breakdown.base_fee + breakdown.distance_fee) * PRICING_CONFIG.night_surcharge_percent / 100)
        breakdown.night_surcharge = true
    end

    -- Peak hour surcharge
    if DeliveryPricing.isPeakHour() then
        surcharges = surcharges + PRICING_CONFIG.peak_hour_surcharge
        breakdown.peak_hour_surcharge = true
    end

    breakdown.surcharges = surcharges

    -- 4. Calculate subtotal
    local subtotal = breakdown.base_fee + breakdown.distance_fee + breakdown.order_value_fee + breakdown.surcharges

    -- 5. Apply discounts (if applicable)
    local discounts = 0

    -- Bulk discount (check if store has multiple active deliveries)
    if store_id and delivery_partner_id then
        local success, result = pcall(function()
            local count = db.query([[
                SELECT COUNT(*) as count
                FROM order_delivery_assignments
                WHERE store_id = ?
                AND delivery_partner_id = ?
                AND status IN ('accepted', 'picked_up', 'in_transit')
                AND created_at > NOW() - INTERVAL '24 hours'
            ]], store_id, delivery_partner_id)
            return count[1].count or 0
        end)

        if success and result >= PRICING_CONFIG.bulk_discount_threshold then
            discounts = subtotal * (PRICING_CONFIG.bulk_discount_percent / 100)
            breakdown.bulk_discount_applied = true
        end
    end

    breakdown.discounts = discounts

    -- 6. Calculate final fee
    local calculated_fee = subtotal - discounts

    -- 7. Apply min/max limits
    calculated_fee = math.max(PRICING_CONFIG.min_delivery_fee, calculated_fee)
    calculated_fee = math.min(PRICING_CONFIG.max_delivery_fee, calculated_fee)

    breakdown.total_fee = math.floor(calculated_fee)
    breakdown.distance_km = distance_km
    breakdown.order_value = order_value

    return breakdown
end

-- Validate partner-proposed fee
function DeliveryPricing.validatePartnerFee(proposed_fee, calculated_fee)
    local proposed = tonumber(proposed_fee)
    local calculated = tonumber(calculated_fee)

    if not proposed or not calculated then
        return false, "Invalid fee values"
    end

    -- Check absolute limits
    if proposed < PRICING_CONFIG.partner_min_fee then
        return false, string.format("Fee too low. Minimum: ₹%d", PRICING_CONFIG.partner_min_fee)
    end

    if proposed > PRICING_CONFIG.partner_max_fee then
        return false, string.format("Fee too high. Maximum: ₹%d", PRICING_CONFIG.partner_max_fee)
    end

    -- Check deviation from calculated fee
    local deviation_percent = math.abs(((proposed - calculated) / calculated) * 100)

    if deviation_percent > PRICING_CONFIG.max_deviation_percent then
        return false, string.format(
            "Fee deviates too much from calculated fee (₹%d). Max deviation: %d%%",
            calculated,
            PRICING_CONFIG.max_deviation_percent
        )
    end

    return true, "Fee is valid"
end

-- Get pricing configuration (for admin/frontend)
function DeliveryPricing.getConfig()
    return PRICING_CONFIG
end

-- Update pricing configuration (admin only)
function DeliveryPricing.updateConfig(new_config)
    -- Validate and merge with existing config
    for key, value in pairs(new_config) do
        if PRICING_CONFIG[key] ~= nil then
            PRICING_CONFIG[key] = value
        end
    end

    return PRICING_CONFIG
end

-- Get fee estimate for frontend display
function DeliveryPricing.getEstimate(distance_km, order_value)
    local breakdown = DeliveryPricing.calculateDeliveryFee({
        distance_km = distance_km,
        order_value = order_value
    })

    return {
        estimated_fee = breakdown.total_fee,
        min_fee = PRICING_CONFIG.min_delivery_fee,
        max_fee = PRICING_CONFIG.max_delivery_fee,
        currency = PRICING_CONFIG.currency,
        breakdown = {
            base = breakdown.base_fee,
            distance = breakdown.distance_fee,
            surcharges = breakdown.surcharges
        }
    }
end

-- Format fee for display
function DeliveryPricing.formatFee(fee, currency)
    currency = currency or PRICING_CONFIG.currency

    local CurrencyHelper = require("helper.currency")
    return CurrencyHelper.format(fee, currency)
end

return DeliveryPricing
