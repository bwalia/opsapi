-- luacheck: max line length 140
--[[
    Customer PO numbers, quote revisions and supplier POs (FEATURES.SHOP)
    =====================================================================

    [1] customer_po_number varchar(64) on shop_quotes and shop_orders: the end customer's own purchase order
        number. Set by staff or by the customer when they authorise; carried to the order, its documents and
        the supplier PO ("End customer PO").
    [2] Quote revisions on shop_quotes: revision_no (0 = the original), revision_of_id (the original, the root
        of the chain), superseded_by_id (the revision that replaced it; the old one is 'cancelled').
    [3] shop_suppliers: how we raise POs with them (po_email, po_phone, po_address, account_number = our
        account with them, po_notes = printed on every PO to them).
    [4] purchase_orders: index on metadata->>'shop_supplier_uuid' and 'shop_order_uuid' (supplier PO lists).
        Skipped when the invoicing feature (purchase_orders) isn't deployed.
    [5] Purchase Orders usable in shop workspaces: for every namespace that uses the shop, add the
        purchase_orders menu entry where it has none (an entry someone switched off stays off) and grant
        purchase_orders to its owner and admin roles where they have no entry for it. Skipped without
        invoicing.

    Registered in migrations.lua as zzs45–zzs49. Idempotent.
]]

local db = require("lapis.db")

local function table_exists(name)
    local r = db.query("SELECT to_regclass(?) IS NOT NULL AS ok", "public." .. name)[1]
    return r and r.ok == true
end

-- Role permissions are JSON text (see migrations/namespace-module.lua). jsonb_exists() rather than the ?
-- operator, which db.query would take for a placeholder.
local PERMS = [[(CASE WHEN COALESCE(r.permissions, '') IN ('', '''{}''') THEN '{}'
                      WHEN r.permissions ~ '^\s*\{' THEN r.permissions END)::jsonb]]

local SHOP_NAMESPACES = [[
    SELECT namespace_id FROM shop_settings
    UNION SELECT namespace_id FROM shop_suppliers
    UNION SELECT namespace_id FROM shop_orders
]]

return {
    [1] = function()
        db.query("ALTER TABLE shop_quotes ADD COLUMN IF NOT EXISTS customer_po_number varchar(64)")
        db.query("ALTER TABLE shop_orders ADD COLUMN IF NOT EXISTS customer_po_number varchar(64)")
    end,

    [2] = function()
        db.query([[
            ALTER TABLE shop_quotes
                ADD COLUMN IF NOT EXISTS revision_no integer NOT NULL DEFAULT 0,
                ADD COLUMN IF NOT EXISTS revision_of_id integer REFERENCES shop_quotes(id) ON DELETE SET NULL,
                ADD COLUMN IF NOT EXISTS superseded_by_id integer REFERENCES shop_quotes(id) ON DELETE SET NULL
        ]])
        db.query([[CREATE INDEX IF NOT EXISTS shop_quotes_revision_of_idx ON shop_quotes (revision_of_id)
                   WHERE revision_of_id IS NOT NULL]])
        db.query([[
            DO $$ BEGIN
                ALTER TABLE shop_quotes ADD CONSTRAINT shop_quotes_revision_no_chk CHECK (revision_no >= 0);
            EXCEPTION WHEN duplicate_object THEN NULL; END $$
        ]])
    end,

    [3] = function()
        db.query([[
            ALTER TABLE shop_suppliers
                ADD COLUMN IF NOT EXISTS po_email varchar(254),
                ADD COLUMN IF NOT EXISTS po_phone varchar(64),
                ADD COLUMN IF NOT EXISTS po_address text,
                ADD COLUMN IF NOT EXISTS account_number varchar(64),
                ADD COLUMN IF NOT EXISTS po_notes text
        ]])
    end,

    [4] = function()
        if not table_exists("purchase_orders") then return end
        db.query([[CREATE INDEX IF NOT EXISTS purchase_orders_shop_supplier_idx
                   ON purchase_orders (namespace_id, (metadata->>'shop_supplier_uuid'))]])
        db.query([[CREATE INDEX IF NOT EXISTS purchase_orders_shop_order_idx
                   ON purchase_orders (namespace_id, (metadata->>'shop_order_uuid'))]])
    end,

    [5] = function()
        if not table_exists("purchase_orders") or not table_exists("namespace_menu_config") then return end
        local item = db.query("SELECT id FROM menu_items WHERE key = 'purchase_orders' LIMIT 1")[1]
        if item then
            local res = db.query([[
                INSERT INTO namespace_menu_config (uuid, namespace_id, menu_item_id, is_enabled, created_at, updated_at)
                SELECT gen_random_uuid()::text, n.id, ?, true, NOW(), NOW()
                  FROM namespaces n
                 WHERE n.id IN (]] .. SHOP_NAMESPACES .. [[)
                   AND NOT EXISTS (SELECT 1 FROM namespace_menu_config c
                                    WHERE c.namespace_id = n.id AND c.menu_item_id = ?)
            ]], item.id, item.id)
            print(("[ShopCustomerPO] purchase_orders menu added to %d shop namespace(s)"):format(res.affected_rows or 0))
        end
        local function grant(names, actions)
            local res = db.query([[
                UPDATE namespace_roles r
                   SET permissions = (]] .. PERMS .. [[ || ?::jsonb)::text, updated_at = NOW()
                 WHERE lower(r.role_name) IN ?
                   AND r.namespace_id IN (]] .. SHOP_NAMESPACES .. [[)
                   AND ]] .. PERMS .. [[ IS NOT NULL
                   AND NOT jsonb_exists(]] .. PERMS .. [[, 'purchase_orders')
            ]], '{"purchase_orders": ' .. actions .. '}', db.list(names))
            return res.affected_rows or 0
        end
        local owners = grant({ "owner", "namespace owner" }, '["create", "read", "update", "delete", "manage"]')
        local admins = grant({ "admin", "namespace admin" }, '["create", "read", "update", "delete"]')
        print(("[ShopCustomerPO] purchase_orders granted to %d owner and %d admin role(s) in shop namespaces")
            :format(owners, admins))
    end,
}
