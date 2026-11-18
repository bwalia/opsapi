-- luacheck: max line length 140
--[[
    Sales orders (core; queries/SalesOrderQueries.lua)
    ==================================================
    [1] orders.source: how a Stores & Products order came in: phone | in_person | email (created by staff on the
        Sales Orders page), pos (a point-of-sale screen), NULL = online store checkout. Skipped where the orders
        table isn't deployed. Idempotent.
    [2] orders.payment_method (cash | card | other) and orders.payment_details (jsonb: tendered, change, reference)
        for sales paid on the spot (the point of sale, queries/PosQueries.lua); index for the till's daily totals.
    [3] "Point of Sale" in the menu (Shop & Orders, module orders, needs create), on wherever Sales Orders is on.
]]

local db = require("lapis.db")

return {
    [1] = function()
        if not db.query("SELECT to_regclass('orders') IS NOT NULL AS ok")[1].ok then return end
        db.query("ALTER TABLE orders ADD COLUMN IF NOT EXISTS source VARCHAR(30)")
    end,

    [2] = function()
        if not db.query("SELECT to_regclass('orders') IS NOT NULL AS ok")[1].ok then return end
        db.query("ALTER TABLE orders ADD COLUMN IF NOT EXISTS payment_method VARCHAR(30)")
        db.query("ALTER TABLE orders ADD COLUMN IF NOT EXISTS payment_details JSONB")
        db.query("CREATE INDEX IF NOT EXISTS orders_store_source_created_idx ON orders (store_id, source, created_at)")
    end,

    [3] = function()
        local ready = db.query("SELECT to_regclass('orders') IS NOT NULL AND to_regclass('menu_items') IS NOT NULL AS ok")[1]
        if not ready.ok then
            return
        end
        db.query([[
            INSERT INTO menu_items (uuid, key, name, icon, path, module, required_action, priority, is_active,
                                    is_admin_only, always_show, settings, created_at, updated_at)
            SELECT gen_random_uuid()::text, 'pos', 'Point of Sale', 'Store', '/dashboard/pos', 'orders', 'create', 9,
                   true, false, false, '{}', NOW(), NOW()
            WHERE NOT EXISTS (SELECT 1 FROM menu_items WHERE key = 'pos')
        ]])
        if db.query("SELECT to_regclass('namespace_menu_config') IS NOT NULL AS ok")[1].ok then
            db.query([[
                INSERT INTO namespace_menu_config (uuid, namespace_id, menu_item_id, is_enabled, created_at, updated_at)
                SELECT gen_random_uuid()::text, c.namespace_id, pos.id, c.is_enabled, NOW(), NOW()
                  FROM namespace_menu_config c
                  JOIN menu_items o ON o.id = c.menu_item_id AND o.key = 'orders'
                  CROSS JOIN menu_items pos
                 WHERE pos.key = 'pos'
                   AND NOT EXISTS (SELECT 1 FROM namespace_menu_config x WHERE x.namespace_id = c.namespace_id
                                   AND x.menu_item_id = pos.id)
            ]])
        end
    end,
}
