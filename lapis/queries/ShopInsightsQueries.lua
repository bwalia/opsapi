-- luacheck: max line length 140
--[[
    Shop trust signals (real data only)
    ===================================
    Daily price snapshots and add-to-basket events behind the product page's
    price-history tab and "added to N baskets in the last 24 hours" signal.
    What may be shown is decided by lib/shop-insights.lua.

    Settings (env, positive integers):
      SHOP_POPULAR_MIN_BASKETS     default 5  — hide the basket count below this
      SHOP_PRICE_HISTORY_MIN_DAYS  default 7  — hide the history tab until this many daily snapshots
]]

local db = require("lapis.db")
local unpack = unpack or table.unpack -- luacheck: ignore 113 143
local U = require("lib.shop-util")
local I = require("lib.shop-insights")

local ShopInsightsQueries = {}

local UK_TODAY = "(NOW() AT TIME ZONE 'Europe/London')::date"
local EVENT_RETENTION_DAYS = 30

--- Upsert today's price for active, priced products (all, or just product_ids).
-- Returns the number of products snapshotted.
function ShopInsightsQueries.snapshotPrices(ns_id, product_ids)
    -- lazy: ShopCatalogQueries requires this module (price-change hook)
    local Catalog = require("queries.ShopCatalogQueries")
    local filter, vals = "", { ns_id }
    if product_ids then
        if #product_ids == 0 then return 0 end
        filter = " AND p.id IN ?"
        vals[#vals + 1] = db.list(product_ids)
    end
    local rows = db.query([[
        INSERT INTO shop_price_history (namespace_id, product_id, day, base_price_minor, from_price_minor, currency,
                                        vat_rate, price_verified, recorded_at)
        SELECT p.namespace_id, p.id, ]] .. UK_TODAY .. [[, p.base_price_minor, ]] .. Catalog.FROM_PRICE_SQL .. [[,
               p.currency, p.vat_rate, p.price_verified, NOW()
          FROM shop_products p
         WHERE p.namespace_id = ? AND p.status = 'active' AND p.price_mode <> 'quote_only'
           AND p.base_price_minor > 0]] .. filter .. [[
        ON CONFLICT (product_id, day) DO UPDATE
           SET base_price_minor = EXCLUDED.base_price_minor, from_price_minor = EXCLUDED.from_price_minor,
               currency = EXCLUDED.currency, vat_rate = EXCLUDED.vat_rate,
               price_verified = EXCLUDED.price_verified, recorded_at = NOW()
        RETURNING product_id
    ]], unpack(vals))
    return #rows
end

--- Daily job: snapshot every product, prune old basket events.
function ShopInsightsQueries.dailySnapshot(ns_id)
    local n = ShopInsightsQueries.snapshotPrices(ns_id)
    local pruned = db.query([[
        DELETE FROM shop_cart_events WHERE namespace_id = ? AND created_at < NOW() - (? || ' days')::interval
        RETURNING id
    ]], ns_id, tostring(EVENT_RETENTION_DAYS))
    return { products_snapshotted = n, cart_events_pruned = #pruned }
end

--- Record one real add-to-basket. Never fails the caller's request.
function ShopInsightsQueries.recordCartAdd(ns_id, cart_id, product_id, qty)
    local ok, err = pcall(db.query, [[
        INSERT INTO shop_cart_events (namespace_id, product_id, cart_id, qty, created_at) VALUES (?, ?, ?, ?, NOW())
    ]], ns_id, product_id, cart_id or db.NULL, math.max(1, U.int(qty, 1)))
    if not ok then ngx.log(ngx.WARN, "[shop-insights] cart event not recorded: ", tostring(err)) end
end

--- Public trust signals for one active product, or nil when not found.
function ShopInsightsQueries.forProduct(ns_id, slug)
    local p = db.query([[
        SELECT id, price_mode FROM shop_products WHERE namespace_id = ? AND slug = ? AND status = 'active'
    ]], ns_id, slug)[1]
    if not p then return nil end

    -- Distinct baskets, so one basket adding repeatedly counts once.
    local baskets = db.query([[
        SELECT COUNT(DISTINCT cart_id)::int AS n FROM shop_cart_events
         WHERE product_id = ? AND cart_id IS NOT NULL AND created_at > NOW() - interval '24 hours'
    ]], p.id)[1].n

    local history
    if p.price_mode ~= "quote_only" then
        local rows = db.query([[
            SELECT day::text AS day, from_price_minor, base_price_minor, price_verified FROM shop_price_history
             WHERE product_id = ? AND day > ]] .. UK_TODAY .. [[ - ?::int ORDER BY day
        ]], p.id, I.HISTORY_DAYS)
        history = I.history(rows, I.setting(U.env("SHOP_PRICE_HISTORY_MIN_DAYS"), I.HISTORY_MIN_DAYS_DEFAULT))
    end

    return {
        baskets_24h = I.popular(baskets, I.setting(U.env("SHOP_POPULAR_MIN_BASKETS"), I.POPULAR_MIN_DEFAULT)) or U.null,
        price_history = history or U.null,
    }
end

return ShopInsightsQueries
