-- luacheck: max line length 140
--[[
    Shop trust signals — pure rules (no nginx, no DB)
    =================================================
    Decides what the product page may show from REAL stored data. UK consumer
    law (CMA guidance, DMCC Act 2024) bans fake urgency and fake counts, so:

      * the basket count is the exact number of distinct baskets, never rounded
        or padded, and is withheld entirely below a minimum;
      * price history is withheld until enough real daily snapshots exist.

    Unit tested by spec/shop-insights-test.lua.
]]

local M = {}

M.POPULAR_MIN_DEFAULT = 5       -- SHOP_POPULAR_MIN_BASKETS
M.HISTORY_MIN_DAYS_DEFAULT = 7  -- SHOP_PRICE_HISTORY_MIN_DAYS
M.HISTORY_DAYS = 365

--- Positive integer setting from a raw env string, else the default.
function M.setting(raw, default)
    local n = tonumber(raw)
    if not n or n < 1 or n ~= math.floor(n) then return default end
    return n
end

--- Exact basket count when it reaches the minimum, else nil (show nothing).
function M.popular(count, min)
    count = tonumber(count) or 0
    if count < 1 or count < min then return nil end
    return math.floor(count)
end

--- Shape stored daily rows (oldest first) for the price-history tab.
-- rows: { day, from_price_minor, base_price_minor, price_verified }
-- Returns nil when fewer than min_days snapshots exist (tab stays hidden).
function M.history(rows, min_days)
    if type(rows) ~= "table" or #rows < min_days then return nil end
    local points = {}
    local low, high
    for i, r in ipairs(rows) do
        local price = math.floor(tonumber(r.from_price_minor) or 0)
        points[i] = { day = tostring(r.day), price_minor = price, verified = r.price_verified == true }
        if not low or price < low then low = price end
        if not high or price > high then high = price end
    end
    local first, last = points[1].price_minor, points[#points].price_minor
    return {
        points = points,
        first_day = points[1].day,
        last_day = points[#points].day,
        first_price_minor = first,
        last_price_minor = last,
        low_price_minor = low,
        high_price_minor = high,
        change_minor = last - first,
    }
end

return M
