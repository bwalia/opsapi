-- luacheck: max line length 140
--[[
    Shop SEO content, product photos and delivery facts (FEATURES.SHOP)
    ===================================================================

    [1] shop_products.seo      per-language target keyword (admin only), title, description, intro,
                               audience, FAQs (lib/shop-seo.lua)
        shop_products.photos   product photos with per-language alt text, first = main photo
        shop_categories.seo    per-language target keyword (admin only), title, description, intro
        shop_settings          UK delivery facts for search engines and the product page, and how long a
                               quote holds its price:
                               delivery_cost_minor (0 = included, as the basket shows),
                               delivery_handling_min/max_days (in-stock items: "Ships in 1-2 days"),
                               delivery_transit_min/max_days, quote_valid_days (30, the old hard-coded
                               quote expiry)

    Registered in migrations.lua as zzs59. Idempotent.
]]

local db = require("lapis.db")

return {
    [1] = function()
        db.query("ALTER TABLE shop_products ADD COLUMN IF NOT EXISTS seo jsonb NOT NULL DEFAULT '{}'::jsonb")
        db.query("ALTER TABLE shop_products ADD COLUMN IF NOT EXISTS photos jsonb NOT NULL DEFAULT '[]'::jsonb")
        db.query("ALTER TABLE shop_categories ADD COLUMN IF NOT EXISTS seo jsonb NOT NULL DEFAULT '{}'::jsonb")
        db.query([[ALTER TABLE shop_settings
                     ADD COLUMN IF NOT EXISTS delivery_cost_minor integer NOT NULL DEFAULT 0
                         CHECK (delivery_cost_minor >= 0),
                     ADD COLUMN IF NOT EXISTS delivery_handling_min_days integer NOT NULL DEFAULT 1
                         CHECK (delivery_handling_min_days BETWEEN 0 AND 60),
                     ADD COLUMN IF NOT EXISTS delivery_handling_max_days integer NOT NULL DEFAULT 2
                         CHECK (delivery_handling_max_days BETWEEN 0 AND 60),
                     ADD COLUMN IF NOT EXISTS delivery_transit_min_days integer NOT NULL DEFAULT 1
                         CHECK (delivery_transit_min_days BETWEEN 0 AND 30),
                     ADD COLUMN IF NOT EXISTS delivery_transit_max_days integer NOT NULL DEFAULT 3
                         CHECK (delivery_transit_max_days BETWEEN 0 AND 30),
                     ADD COLUMN IF NOT EXISTS quote_valid_days integer NOT NULL DEFAULT 30
                         CHECK (quote_valid_days BETWEEN 1 AND 365)]])
    end,
}
