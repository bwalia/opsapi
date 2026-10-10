--[[
    Purchase Orders Migrations
    ==========================

    Core purchase-order module: a business raises POs to suppliers (builders,
    merchants), sends them, tracks goods received line by line, and turns a
    received PO into a bill (an expense in the accounting purchase ledger when
    the accounting feature is on).

    Feature-gated under FEATURES.INVOICING in migrations.lua (same as invoices).
    Every step is idempotent (IF NOT EXISTS / existence checks), so re-running is
    harmless.

    Tables:
      purchase_orders           - PO header (namespace-scoped)
      purchase_order_items      - lines (quantity, unit price, tax, received qty)
      purchase_order_sequences  - per-namespace PO number counter (PO-000001)

    supplier_company_uuid (crm_accounts.uuid) and project_uuid
    (kanban_projects.uuid) are soft links with no FK: CRM and Kanban are
    separate features and their tables may not exist in an invoicing-only
    deployment. The queries validate them, namespace-scoped, when present.

    Steps:
      [1] tables + indexes
      [2] menu item (key purchase_orders, next to Invoices)
      [3] RBAC module registry row
      [4] grant owner/admin roles on purchase_orders
      [5] enable the menu item for every existing namespace
]]

local db = require("lapis.db")

return {
    -- =========================================================================
    -- [1] Tables
    -- =========================================================================
    [1] = function()
        db.query([[
            CREATE TABLE IF NOT EXISTS purchase_orders (
                id BIGSERIAL PRIMARY KEY,
                uuid TEXT UNIQUE NOT NULL,
                namespace_id BIGINT NOT NULL REFERENCES namespaces(id) ON DELETE CASCADE,
                po_number TEXT NOT NULL,
                status TEXT NOT NULL DEFAULT 'draft' CHECK (status IN (
                    'draft','sent','acknowledged','partially_received','received','billed','cancelled'
                )),
                supplier_name TEXT NOT NULL,
                supplier_email TEXT,
                supplier_phone TEXT,
                supplier_address TEXT,
                supplier_company_uuid TEXT,
                reference TEXT,
                issue_date DATE NOT NULL DEFAULT CURRENT_DATE,
                expected_date DATE,
                delivery_address TEXT,
                currency TEXT NOT NULL DEFAULT 'GBP',
                notes TEXT,
                terms TEXT,
                subtotal DECIMAL(15,2) NOT NULL DEFAULT 0,
                tax_total DECIMAL(15,2) NOT NULL DEFAULT 0,
                total DECIMAL(15,2) NOT NULL DEFAULT 0,
                project_uuid TEXT,
                metadata JSONB NOT NULL DEFAULT '{}',
                created_by_uuid TEXT,
                sent_at TIMESTAMP,
                acknowledged_at TIMESTAMP,
                received_at TIMESTAMP,
                billed_at TIMESTAMP,
                cancelled_at TIMESTAMP,
                created_at TIMESTAMP NOT NULL DEFAULT NOW(),
                updated_at TIMESTAMP NOT NULL DEFAULT NOW(),
                deleted_at TIMESTAMP
            )
        ]])

        -- PO numbers are unique per namespace (they come from a sequence and are
        -- never reused, so this holds across soft-deleted rows too).
        db.query([[
            CREATE UNIQUE INDEX IF NOT EXISTS idx_purchase_orders_namespace_number
            ON purchase_orders (namespace_id, po_number)
        ]])
        db.query([[
            CREATE INDEX IF NOT EXISTS idx_purchase_orders_namespace_status
            ON purchase_orders (namespace_id, status) WHERE deleted_at IS NULL
        ]])
        db.query([[
            CREATE INDEX IF NOT EXISTS idx_purchase_orders_namespace_issue_date
            ON purchase_orders (namespace_id, issue_date) WHERE deleted_at IS NULL
        ]])
        db.query([[
            CREATE INDEX IF NOT EXISTS idx_purchase_orders_namespace_project
            ON purchase_orders (namespace_id, project_uuid) WHERE project_uuid IS NOT NULL
        ]])
        db.query([[
            CREATE INDEX IF NOT EXISTS idx_purchase_orders_namespace_supplier_company
            ON purchase_orders (namespace_id, supplier_company_uuid) WHERE supplier_company_uuid IS NOT NULL
        ]])

        db.query([[
            CREATE TABLE IF NOT EXISTS purchase_order_items (
                id BIGSERIAL PRIMARY KEY,
                uuid TEXT UNIQUE NOT NULL,
                purchase_order_id BIGINT NOT NULL REFERENCES purchase_orders(id) ON DELETE CASCADE,
                namespace_id BIGINT NOT NULL REFERENCES namespaces(id) ON DELETE CASCADE,
                description TEXT NOT NULL,
                quantity DECIMAL(15,3) NOT NULL DEFAULT 1 CHECK (quantity > 0),
                unit_price DECIMAL(15,2) NOT NULL DEFAULT 0,
                tax_rate DECIMAL(6,2) NOT NULL DEFAULT 0,
                tax_amount DECIMAL(15,2) NOT NULL DEFAULT 0,
                line_total DECIMAL(15,2) NOT NULL DEFAULT 0,
                received_quantity DECIMAL(15,3) NOT NULL DEFAULT 0 CHECK (received_quantity >= 0),
                sort_order INTEGER NOT NULL DEFAULT 0,
                created_at TIMESTAMP NOT NULL DEFAULT NOW(),
                updated_at TIMESTAMP NOT NULL DEFAULT NOW()
            )
        ]])
        db.query([[
            CREATE INDEX IF NOT EXISTS idx_purchase_order_items_po
            ON purchase_order_items (purchase_order_id, sort_order)
        ]])
        db.query([[
            CREATE INDEX IF NOT EXISTS idx_purchase_order_items_namespace
            ON purchase_order_items (namespace_id)
        ]])

        db.query([[
            CREATE TABLE IF NOT EXISTS purchase_order_sequences (
                namespace_id BIGINT PRIMARY KEY REFERENCES namespaces(id) ON DELETE CASCADE,
                prefix TEXT NOT NULL DEFAULT 'PO',
                current_number BIGINT NOT NULL DEFAULT 0,
                created_at TIMESTAMP NOT NULL DEFAULT NOW(),
                updated_at TIMESTAMP NOT NULL DEFAULT NOW()
            )
        ]])
    end,

    -- =========================================================================
    -- [2] Menu item, right after Invoices (priority 40)
    -- =========================================================================
    [2] = function()
        local MigrationUtils = require("helper.migration-utils")
        local timestamp = MigrationUtils.getCurrentTimestamp()

        local existing = db.select("* FROM menu_items WHERE key = ?", "purchase_orders")
        if #existing == 0 then
            db.insert("menu_items", {
                uuid = MigrationUtils.generateUUID(),
                key = "purchase_orders",
                name = "Purchase Orders",
                icon = "ClipboardCheck",
                path = "/dashboard/purchase-orders",
                module = "purchase_orders",
                required_action = "read",
                priority = 41,
                is_active = true,
                is_admin_only = false,
                always_show = false,
                settings = "{}",
                created_at = timestamp,
                updated_at = timestamp,
            })
            print("[PurchaseOrders] Added menu item: purchase_orders")
        end
    end,

    -- =========================================================================
    -- [3] Register the RBAC module
    -- =========================================================================
    [3] = function()
        local MigrationUtils = require("helper.migration-utils")
        local timestamp = MigrationUtils.getCurrentTimestamp()

        local existing = db.select("* FROM modules WHERE machine_name = ?", "purchase_orders")
        if #existing == 0 then
            db.insert("modules", {
                uuid = MigrationUtils.generateUUID(),
                machine_name = "purchase_orders",
                name = "Purchase Orders",
                description = "Raise, send, receive and bill supplier purchase orders",
                priority = 43,
                created_at = timestamp,
                updated_at = timestamp,
            })
            print("[PurchaseOrders] Registered module: purchase_orders")
        end
    end,

    -- =========================================================================
    -- [4] Grant owner + admin roles (members get nothing by default)
    -- =========================================================================
    [4] = function()
        local cjson_ok, cjson = pcall(require, "cjson")
        if not cjson_ok then return end

        local function grant(role_names, actions)
            local roles = db.select("* FROM namespace_roles WHERE role_name IN ?", db.list(role_names))
            for _, role in ipairs(roles) do
                local perms = {}
                if type(role.permissions) == "table" then
                    perms = role.permissions
                elseif role.permissions and role.permissions ~= "" then
                    local ok, decoded = pcall(cjson.decode, role.permissions)
                    if ok and type(decoded) == "table" then perms = decoded end
                end
                if not perms.purchase_orders then
                    perms.purchase_orders = actions
                    db.update("namespace_roles", { permissions = cjson.encode(perms) }, { id = role.id })
                end
            end
        end

        grant({ "Owner", "owner", "Namespace Owner" }, { "create", "read", "update", "delete", "manage" })
        grant({ "Admin", "admin", "Namespace Admin" }, { "create", "read", "update", "delete" })
    end,

    -- =========================================================================
    -- [5] Enable the menu item for all existing namespaces
    -- =========================================================================
    [5] = function()
        db.query([[
            INSERT INTO namespace_menu_config (uuid, namespace_id, menu_item_id, is_enabled, created_at, updated_at)
            SELECT gen_random_uuid()::text, n.id, mi.id, true, NOW(), NOW()
            FROM namespaces n
            CROSS JOIN menu_items mi
            WHERE mi.key = 'purchase_orders'
              AND NOT EXISTS (
                  SELECT 1 FROM namespace_menu_config c
                  WHERE c.namespace_id = n.id AND c.menu_item_id = mi.id
              )
        ]])
    end,
}
