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
      [6] several bills per PO: purchase_order_items.billed_quantity (+ the
          billed_net / billed_tax pennies, so bills always add up); old
          single-bill POs (metadata.bill / expense_uuid / expense_id) become
          metadata.bills[1]; line amounts re-derived from the stored values
      [7] RBAC module category = Finance (as in PROJECT_MODULES)
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

    -- =========================================================================
    -- [6] Several bills per PO
    -- =========================================================================
    [6] = function()
        db.query([[
            ALTER TABLE purchase_order_items
            ADD COLUMN IF NOT EXISTS billed_quantity DECIMAL(15,3) NOT NULL DEFAULT 0 CHECK (billed_quantity >= 0),
            ADD COLUMN IF NOT EXISTS billed_net DECIMAL(15,2) NOT NULL DEFAULT 0,
            ADD COLUMN IF NOT EXISTS billed_tax DECIMAL(15,2) NOT NULL DEFAULT 0
        ]])
        db.query([[
            DO $$ BEGIN
                IF NOT EXISTS (SELECT 1 FROM pg_constraint
                               WHERE conname = 'purchase_order_items_billed_le_received') THEN
                    ALTER TABLE purchase_order_items ADD CONSTRAINT purchase_order_items_billed_le_received
                        CHECK (billed_quantity <= received_quantity);
                END IF;
            END $$
        ]])

        -- A PO billed before this release was billed once, for everything received.
        db.query([[
            UPDATE purchase_order_items i
            SET billed_quantity = i.received_quantity,
                billed_net = ROUND(i.received_quantity * i.unit_price, 2),
                billed_tax = ROUND(ROUND(i.received_quantity * i.unit_price, 2) * i.tax_rate / 100, 2)
            FROM purchase_orders po
            WHERE po.id = i.purchase_order_id AND po.namespace_id = i.namespace_id
              AND po.status = 'billed' AND i.billed_quantity = 0
        ]])
        db.query([[
            UPDATE purchase_orders po
            SET metadata = (po.metadata - 'bill' - 'expense_id' - 'expense_uuid') || jsonb_build_object('bills',
                jsonb_build_array(CASE WHEN jsonb_typeof(po.metadata->'bill') = 'object'
                    THEN po.metadata->'bill' ELSE '{}'::jsonb END || jsonb_build_object(
                    'uuid', gen_random_uuid()::text,
                    'at', to_char(COALESCE(po.billed_at, po.updated_at), 'YYYY-MM-DD HH24:MI:SS'),
                    'expense_uuid', COALESCE(po.metadata->'bill'->'expense_uuid', po.metadata->'expense_uuid',
                        'null'::jsonb),
                    'lines', COALESCE((
                        SELECT jsonb_agg(jsonb_build_object('item_uuid', i.uuid, 'quantity', i.received_quantity,
                            'net', i.billed_net, 'tax', i.billed_tax))
                        FROM purchase_order_items i
                        WHERE i.purchase_order_id = po.id AND i.namespace_id = po.namespace_id
                          AND i.received_quantity > 0), '[]'::jsonb))))
            WHERE po.status = 'billed' AND NOT po.metadata ? 'bills'
        ]])
        -- Never billed: drop forged bill keys (metadata used to be client-writable).
        db.query([[
            UPDATE purchase_orders SET metadata = metadata - 'bill' - 'expense_id' - 'expense_uuid'
            WHERE status <> 'billed' AND (metadata ? 'bill' OR metadata ? 'expense_id' OR metadata ? 'expense_uuid')
        ]])

        -- Line amounts used to be worked out from the unrounded unit price:
        -- re-derive them from the stored values (the rule the queries now use).
        db.query([[
            UPDATE purchase_order_items
            SET tax_amount = v.tax, line_total = v.net + v.tax
            FROM (
                SELECT id, ROUND(quantity * unit_price, 2) AS net,
                       ROUND(ROUND(quantity * unit_price, 2) * tax_rate / 100, 2) AS tax
                FROM purchase_order_items
            ) v
            WHERE purchase_order_items.id = v.id
              AND (purchase_order_items.tax_amount <> v.tax OR purchase_order_items.line_total <> v.net + v.tax)
        ]])
        db.query([[
            UPDATE purchase_orders po
            SET subtotal = t.subtotal, tax_total = t.tax_total, total = t.total
            FROM (
                SELECT purchase_order_id, namespace_id, SUM(ROUND(quantity * unit_price, 2)) AS subtotal,
                       SUM(tax_amount) AS tax_total, SUM(line_total) AS total
                FROM purchase_order_items GROUP BY purchase_order_id, namespace_id
            ) t
            WHERE po.id = t.purchase_order_id AND po.namespace_id = t.namespace_id
              AND (po.subtotal <> t.subtotal OR po.tax_total <> t.tax_total OR po.total <> t.total)
        ]])
    end,

    -- =========================================================================
    -- [7] RBAC module category (step 3 registered it without one)
    -- =========================================================================
    [7] = function()
        db.query([[
            UPDATE modules SET category = 'Finance', updated_at = NOW()
            WHERE machine_name = 'purchase_orders' AND (category IS NULL OR category = '')
        ]])
    end,
}
