--[[
    Supplier portal (FEATURES.SHOP; needs purchase orders, FEATURES.INVOICING)
    =========================================================================
    Purchase orders, proforma invoices, payments and deliveries managed online with the supplier instead of by
    email (lib/supplier-portal.lua, queries/SupplierPortalQueries.lua, routes/supplier-portal.lua).

    [1] tables (each skipped when purchase_orders / shop_suppliers aren't deployed):
        supplier_portal_users            a supplier contact's login: users.id ↔ shop_suppliers.id (one supplier
                                         per login); status invited | active | disabled
        purchase_order_documents         typed files on a PO (stored privately in MinIO, never public): our PO,
                                         proforma, payment proof, VAT invoice, delivery note, proof of delivery,
                                         credit note, other; soft-deleted by staff only
        purchase_order_supplier_invoices proforma / final VAT invoice / credit note records (number, date, supplier
                                         order ref, net, VAT, total, terms, Incoterm, due date)
        purchase_order_payments          our payments (amount, sent / cleared dates, method, bank transaction id,
                                         reference, against which proforma or invoice, proof); voided, never deleted
        purchase_order_shipments         dispatch (carrier, tracking, dates) and delivery (date, received by, POD)
        purchase_order_messages          the per-PO message thread between staff and the supplier
        purchase_orders.portal_stage     the supplier-facing stage (+ portal_stage_at, closed_at)
        namespace_audit_logs index       (namespace_id, entity_type, entity_id): the PO history
    [2] shop_settings.supplier_portal_enabled and supplier_portal_emails_enabled, both default false: the portal
        is off until staff switch it on, and nothing is emailed to suppliers until that is switched on too.
    [3] "Purchase Invoices" in the menu (Finance, next to Purchase Orders, same RBAC module purchase_orders):
        every supplier invoice, proforma and credit note across POs (queries/PurchaseInvoiceQueries.lua).

    Idempotent: IF NOT EXISTS everywhere, so running it again changes nothing.
]]

local db = require("lapis.db")

local function table_exists(name)
    local r = db.query("SELECT to_regclass(?) IS NOT NULL AS ok", "public." .. name)
    return r and r[1] and r[1].ok == true
end

return {
    [1] = function()
        if not table_exists("purchase_orders") or not table_exists("shop_suppliers") then
            print("[SupplierPortal] purchase_orders or shop_suppliers not deployed: skipped")
            return
        end

        db.query([[
            CREATE TABLE IF NOT EXISTS supplier_portal_users (
                id BIGSERIAL PRIMARY KEY,
                uuid TEXT UNIQUE NOT NULL,
                namespace_id BIGINT NOT NULL REFERENCES namespaces(id) ON DELETE CASCADE,
                supplier_id INTEGER NOT NULL REFERENCES shop_suppliers(id) ON DELETE CASCADE,
                user_id INTEGER NOT NULL REFERENCES users(id) ON DELETE CASCADE,
                contact_name TEXT,
                email TEXT NOT NULL,
                status TEXT NOT NULL DEFAULT 'invited' CHECK (status IN ('invited', 'active', 'disabled')),
                invited_by_user_id INTEGER,
                invited_at TIMESTAMP NOT NULL DEFAULT NOW(),
                activated_at TIMESTAMP,
                disabled_at TIMESTAMP,
                last_seen_at TIMESTAMP,
                created_at TIMESTAMP NOT NULL DEFAULT NOW(),
                updated_at TIMESTAMP NOT NULL DEFAULT NOW()
            )
        ]])
        -- One login is one supplier's contact, everywhere.
        db.query("CREATE UNIQUE INDEX IF NOT EXISTS supplier_portal_users_user_idx ON supplier_portal_users (user_id)")
        db.query([[CREATE INDEX IF NOT EXISTS supplier_portal_users_supplier_idx
                   ON supplier_portal_users (namespace_id, supplier_id)]])

        db.query([[
            CREATE TABLE IF NOT EXISTS purchase_order_documents (
                id BIGSERIAL PRIMARY KEY,
                uuid TEXT UNIQUE NOT NULL,
                namespace_id BIGINT NOT NULL REFERENCES namespaces(id) ON DELETE CASCADE,
                purchase_order_id BIGINT NOT NULL REFERENCES purchase_orders(id) ON DELETE CASCADE,
                doc_type TEXT NOT NULL CHECK (doc_type IN ('purchase_order', 'proforma', 'payment_proof',
                    'vat_invoice', 'delivery_note', 'proof_of_delivery', 'credit_note', 'other')),
                filename TEXT NOT NULL,
                content_type TEXT NOT NULL,
                size_bytes BIGINT NOT NULL CHECK (size_bytes > 0 AND size_bytes <= 20971520),
                sha256 TEXT NOT NULL,
                storage_bucket TEXT,
                storage_key TEXT NOT NULL,
                scan_status TEXT NOT NULL DEFAULT 'not_scanned'
                    CHECK (scan_status IN ('not_scanned', 'clean', 'infected', 'error')),
                visible_to_supplier BOOLEAN NOT NULL DEFAULT true,
                note TEXT,
                uploaded_by_user_id INTEGER,
                uploaded_by_kind TEXT NOT NULL CHECK (uploaded_by_kind IN ('staff', 'supplier')),
                created_at TIMESTAMP NOT NULL DEFAULT NOW(),
                deleted_at TIMESTAMP,
                deleted_by_user_id INTEGER,
                delete_reason TEXT
            )
        ]])
        db.query([[CREATE INDEX IF NOT EXISTS purchase_order_documents_po_idx
                   ON purchase_order_documents (namespace_id, purchase_order_id, created_at)]])

        db.query([[
            CREATE TABLE IF NOT EXISTS purchase_order_supplier_invoices (
                id BIGSERIAL PRIMARY KEY,
                uuid TEXT UNIQUE NOT NULL,
                namespace_id BIGINT NOT NULL REFERENCES namespaces(id) ON DELETE CASCADE,
                purchase_order_id BIGINT NOT NULL REFERENCES purchase_orders(id) ON DELETE CASCADE,
                kind TEXT NOT NULL CHECK (kind IN ('proforma', 'invoice', 'credit_note')),
                number TEXT NOT NULL,
                invoice_date DATE NOT NULL,
                due_date DATE,
                supplier_order_ref TEXT,
                net NUMERIC(15,2) NOT NULL CHECK (net >= 0),
                vat NUMERIC(15,2) NOT NULL CHECK (vat >= 0),
                total NUMERIC(15,2) NOT NULL CHECK (total >= 0),
                currency TEXT NOT NULL DEFAULT 'GBP',
                payment_terms TEXT,
                incoterm TEXT,
                bank_details TEXT,
                note TEXT,
                document_id BIGINT REFERENCES purchase_order_documents(id) ON DELETE SET NULL,
                created_by_user_id INTEGER,
                created_by_kind TEXT NOT NULL CHECK (created_by_kind IN ('staff', 'supplier')),
                created_at TIMESTAMP NOT NULL DEFAULT NOW(),
                updated_at TIMESTAMP NOT NULL DEFAULT NOW(),
                deleted_at TIMESTAMP,
                deleted_by_user_id INTEGER,
                delete_reason TEXT
            )
        ]])
        db.query([[CREATE INDEX IF NOT EXISTS purchase_order_supplier_invoices_po_idx
                   ON purchase_order_supplier_invoices (namespace_id, purchase_order_id, created_at)]])
        -- One number per kind per PO (a revised proforma gets a new number or replaces the old one).
        db.query([[CREATE UNIQUE INDEX IF NOT EXISTS purchase_order_supplier_invoices_number_idx
                   ON purchase_order_supplier_invoices (namespace_id, purchase_order_id, kind, lower(number))
                   WHERE deleted_at IS NULL]])

        db.query([[
            CREATE TABLE IF NOT EXISTS purchase_order_payments (
                id BIGSERIAL PRIMARY KEY,
                uuid TEXT UNIQUE NOT NULL,
                namespace_id BIGINT NOT NULL REFERENCES namespaces(id) ON DELETE CASCADE,
                purchase_order_id BIGINT NOT NULL REFERENCES purchase_orders(id) ON DELETE CASCADE,
                supplier_invoice_id BIGINT REFERENCES purchase_order_supplier_invoices(id) ON DELETE SET NULL,
                amount NUMERIC(15,2) NOT NULL CHECK (amount > 0),
                currency TEXT NOT NULL DEFAULT 'GBP',
                method TEXT NOT NULL CHECK (method IN ('faster_payment', 'bacs', 'chaps', 'card', 'other')),
                sent_on DATE NOT NULL,
                cleared_on DATE,
                bank_transaction_id TEXT,
                payment_reference TEXT,
                proof_document_id BIGINT REFERENCES purchase_order_documents(id) ON DELETE SET NULL,
                note TEXT,
                created_by_user_id INTEGER,
                created_at TIMESTAMP NOT NULL DEFAULT NOW(),
                updated_at TIMESTAMP NOT NULL DEFAULT NOW(),
                voided_at TIMESTAMP,
                voided_by_user_id INTEGER,
                void_reason TEXT
            )
        ]])
        db.query([[CREATE INDEX IF NOT EXISTS purchase_order_payments_po_idx
                   ON purchase_order_payments (namespace_id, purchase_order_id, sent_on)]])

        db.query([[
            CREATE TABLE IF NOT EXISTS purchase_order_shipments (
                id BIGSERIAL PRIMARY KEY,
                uuid TEXT UNIQUE NOT NULL,
                namespace_id BIGINT NOT NULL REFERENCES namespaces(id) ON DELETE CASCADE,
                purchase_order_id BIGINT NOT NULL REFERENCES purchase_orders(id) ON DELETE CASCADE,
                carrier TEXT NOT NULL,
                tracking_number TEXT,
                tracking_url TEXT,
                dispatched_on DATE NOT NULL,
                expected_on DATE,
                delivered_on DATE,
                received_by TEXT,
                pod_document_id BIGINT REFERENCES purchase_order_documents(id) ON DELETE SET NULL,
                note TEXT,
                delivery_note TEXT,
                created_by_user_id INTEGER,
                created_by_kind TEXT NOT NULL CHECK (created_by_kind IN ('staff', 'supplier')),
                delivered_by_user_id INTEGER,
                delivered_by_kind TEXT CHECK (delivered_by_kind IS NULL OR delivered_by_kind IN ('staff', 'supplier')),
                created_at TIMESTAMP NOT NULL DEFAULT NOW(),
                updated_at TIMESTAMP NOT NULL DEFAULT NOW()
            )
        ]])
        db.query([[CREATE INDEX IF NOT EXISTS purchase_order_shipments_po_idx
                   ON purchase_order_shipments (namespace_id, purchase_order_id, dispatched_on)]])

        db.query([[
            CREATE TABLE IF NOT EXISTS purchase_order_messages (
                id BIGSERIAL PRIMARY KEY,
                uuid TEXT UNIQUE NOT NULL,
                namespace_id BIGINT NOT NULL REFERENCES namespaces(id) ON DELETE CASCADE,
                purchase_order_id BIGINT NOT NULL REFERENCES purchase_orders(id) ON DELETE CASCADE,
                author_user_id INTEGER,
                author_kind TEXT NOT NULL CHECK (author_kind IN ('staff', 'supplier')),
                body TEXT NOT NULL CHECK (length(body) BETWEEN 1 AND 4000),
                created_at TIMESTAMP NOT NULL DEFAULT NOW(),
                deleted_at TIMESTAMP
            )
        ]])
        db.query([[CREATE INDEX IF NOT EXISTS purchase_order_messages_po_idx
                   ON purchase_order_messages (namespace_id, purchase_order_id, created_at)]])

        db.query([[
            ALTER TABLE purchase_orders
            ADD COLUMN IF NOT EXISTS portal_stage TEXT,
            ADD COLUMN IF NOT EXISTS portal_stage_at TIMESTAMP,
            ADD COLUMN IF NOT EXISTS closed_at TIMESTAMP
        ]])
        db.query([[
            DO $$ BEGIN
                IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conname = 'purchase_orders_portal_stage_check') THEN
                    ALTER TABLE purchase_orders ADD CONSTRAINT purchase_orders_portal_stage_check CHECK (
                        portal_stage IS NULL OR portal_stage IN ('draft', 'sent', 'acknowledged', 'proforma_received',
                        'part_paid', 'paid', 'dispatched', 'delivered', 'invoiced', 'closed', 'cancelled'));
                END IF;
            END $$
        ]])

        if table_exists("namespace_audit_logs") then
            db.query([[CREATE INDEX IF NOT EXISTS namespace_audit_logs_entity_idx
                       ON namespace_audit_logs (namespace_id, entity_type, entity_id)]])
        end
        print("[SupplierPortal] tables ready")
    end,

    [2] = function()
        if not table_exists("shop_settings") then return end
        db.query([[
            ALTER TABLE shop_settings
            ADD COLUMN IF NOT EXISTS supplier_portal_enabled BOOLEAN NOT NULL DEFAULT false,
            ADD COLUMN IF NOT EXISTS supplier_portal_emails_enabled BOOLEAN NOT NULL DEFAULT false
        ]])
    end,

    [3] = function()
        if not table_exists("purchase_order_supplier_invoices") or not table_exists("menu_items") then return end
        db.query([[
            INSERT INTO menu_items (uuid, key, name, icon, path, module, required_action, priority, is_active,
                                    is_admin_only, always_show, settings, created_at, updated_at)
            SELECT gen_random_uuid()::text, 'purchase_invoices', 'Purchase Invoices', 'Receipt', '/dashboard/purchase-invoices',
                   'purchase_orders', 'read', 42, true, false, false, '{}', NOW(), NOW()
            WHERE NOT EXISTS (SELECT 1 FROM menu_items WHERE key = 'purchase_invoices')
        ]])
        -- On wherever Purchase Orders is on.
        if table_exists("namespace_menu_config") then
            db.query([[
                INSERT INTO namespace_menu_config (uuid, namespace_id, menu_item_id, is_enabled, created_at, updated_at)
                SELECT gen_random_uuid()::text, c.namespace_id, pi.id, c.is_enabled, NOW(), NOW()
                  FROM namespace_menu_config c
                  JOIN menu_items po ON po.id = c.menu_item_id AND po.key = 'purchase_orders'
                  CROSS JOIN menu_items pi
                 WHERE pi.key = 'purchase_invoices'
                   AND NOT EXISTS (SELECT 1 FROM namespace_menu_config x WHERE x.namespace_id = c.namespace_id AND x.menu_item_id = pi.id)
            ]])
        end
    end,
}
