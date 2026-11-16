-- luacheck: max line length 140
--[[
    Never price below cost (FEATURES.SHOP)
    ======================================

    Costs (pence, ex VAT) the shop checks every price against (lib/shop-cost.lua, queries/ShopCostQueries.lua):

    [1] shop_products.cost_minor  manual cost, used when the product has no linked supplier item
                                  (effective cost = supplier item cost, else this, else unknown)
        shop_options.cost_minor   cost of one unit of the option's price delta when it has no component product
                                  (an option with a component product costs what the component costs)
        shop_price_changes.status gains 'blocked_below_cost': a supplier sync never sets a price below cost
        shop_cost_alerts          one staff alert per product per day when a customer is stopped at a
                                  below-cost price (basket checkout, quote, order)

    Registered in migrations.lua as zzs54. Idempotent.
]]

local db = require("lapis.db")

return {
    [1] = function()
        db.query([[ALTER TABLE shop_products ADD COLUMN IF NOT EXISTS cost_minor integer
                   CHECK (cost_minor IS NULL OR cost_minor >= 0)]])
        db.query([[ALTER TABLE shop_options ADD COLUMN IF NOT EXISTS cost_minor integer
                   CHECK (cost_minor IS NULL OR cost_minor >= 0)]])
        db.query([[ALTER TABLE shop_price_changes ALTER COLUMN status TYPE varchar(32)]])
        db.query([[ALTER TABLE shop_price_changes DROP CONSTRAINT IF EXISTS shop_price_changes_status_check]])
        db.query([[ALTER TABLE shop_price_changes ADD CONSTRAINT shop_price_changes_status_check
                   CHECK (status IN ('applied', 'pending', 'approved', 'rejected', 'superseded', 'blocked_below_cost'))]])
        db.query([[
            CREATE TABLE IF NOT EXISTS shop_cost_alerts (
                namespace_id integer NOT NULL REFERENCES namespaces(id) ON DELETE CASCADE,
                product_id integer NOT NULL REFERENCES shop_products(id) ON DELETE CASCADE,
                day date NOT NULL DEFAULT CURRENT_DATE,
                created_at timestamptz NOT NULL DEFAULT NOW(),
                PRIMARY KEY (product_id, day)
            )
        ]])
    end,
}
