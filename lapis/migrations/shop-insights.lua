--[[
    Shop trust-signal migrations (FEATURES.SHOP)
    ============================================

    Real data behind the product-page trust signals. Nothing here is ever
    estimated or padded: the shop shows only what these tables hold.

      shop_price_history  one row per product per UK calendar day: the price a
                          customer saw that day (last write of the day wins).
                          Written by the market-sync CronJob
                          (POST /api/v2/shop/admin/market/snapshot-prices) and
                          whenever an admin or the market apply-price changes
                          a product. Feeds the 12-month price-history tab.
      shop_cart_events    one row per real "add to basket". Feeds the
                          "added to N baskets in the last 24 hours" signal.
                          Rows older than 30 days are pruned by the snapshot job.

    Registered in migrations.lua as zzs16/zzs17. Idempotent.
]]

local db = require("lapis.db")

return {
    -- [1] daily price snapshots ---------------------------------------------------
    [1] = function()
        db.query([[
            CREATE TABLE IF NOT EXISTS shop_price_history (
                id bigserial PRIMARY KEY,
                namespace_id integer NOT NULL REFERENCES namespaces(id) ON DELETE CASCADE,
                product_id integer NOT NULL REFERENCES shop_products(id) ON DELETE CASCADE,
                day date NOT NULL,
                base_price_minor integer NOT NULL,
                from_price_minor integer NOT NULL,
                currency varchar(3) NOT NULL DEFAULT 'GBP',
                vat_rate numeric(5,4) NOT NULL DEFAULT 0.20,
                price_verified boolean NOT NULL DEFAULT false,
                recorded_at timestamptz NOT NULL DEFAULT NOW(),
                UNIQUE (product_id, day)
            )
        ]])
        db.query([[
            CREATE INDEX IF NOT EXISTS shop_price_history_ns_day_idx ON shop_price_history (namespace_id, day)
        ]])
    end,

    -- [2] add-to-basket events ------------------------------------------------------
    [2] = function()
        db.query([[
            CREATE TABLE IF NOT EXISTS shop_cart_events (
                id bigserial PRIMARY KEY,
                namespace_id integer NOT NULL REFERENCES namespaces(id) ON DELETE CASCADE,
                product_id integer NOT NULL REFERENCES shop_products(id) ON DELETE CASCADE,
                cart_id integer REFERENCES shop_carts(id) ON DELETE SET NULL,
                qty integer NOT NULL DEFAULT 1,
                created_at timestamptz NOT NULL DEFAULT NOW()
            )
        ]])
        db.query([[
            CREATE INDEX IF NOT EXISTS shop_cart_events_product_idx ON shop_cart_events (product_id, created_at DESC)
        ]])
    end,
}
