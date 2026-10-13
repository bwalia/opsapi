--[[
    Shop supplier catalogue sync (FEATURES.SHOP)
    ============================================

    Suppliers' price files (CSV / JSON / XML, fetched from a URL or uploaded)
    become supplier items with a daily cost history. A shop product linked to
    a supplier item and set to pricing_source = 'supplier' is priced at
    cost × (1 + margin %); small changes apply automatically, bigger ones wait
    in shop_price_changes for an admin.

      shop_suppliers                 feed settings, column mapping, keyword filter,
                                     default margin, change threshold; feed login
                                     encrypted (write-only)
      shop_supplier_items            one row per supplier SKU (cost ex VAT, stock, lead time)
      shop_supplier_price_history    one row per item per UK day
      shop_price_changes             every supplier-driven price change: applied, or
                                     pending / approved / rejected by an admin
      shop_supplier_contacts         (data model only) supplier portal logins — no endpoints yet
      shop_supplier_bids             (data model only) supplier bids on our requests — no endpoints yet

    Plus shop_products.pricing_source / margin_pct / supplier_item_id and
    shop_categories.margin_pct.

    Registered in migrations.lua as zzs22–zzs24. Idempotent.
]]

local db = require("lapis.db")

return {
    -- [1] suppliers + items + daily history ---------------------------------------------------
    [1] = function()
        db.query([[
            CREATE TABLE IF NOT EXISTS shop_suppliers (
                id serial PRIMARY KEY,
                uuid varchar(64) NOT NULL UNIQUE,
                namespace_id integer NOT NULL REFERENCES namespaces(id) ON DELETE CASCADE,
                name varchar(255) NOT NULL,
                feed_format varchar(8) NOT NULL DEFAULT 'csv' CHECK (feed_format IN ('csv', 'json', 'xml')),
                feed_url text,
                feed_options jsonb NOT NULL DEFAULT '{}'::jsonb,
                auth_type varchar(8) NOT NULL DEFAULT 'none' CHECK (auth_type IN ('none', 'basic', 'bearer', 'header')),
                auth_username varchar(255),
                auth_header_name varchar(100),
                auth_secret_encrypted text,
                mapping jsonb NOT NULL DEFAULT '{}'::jsonb,
                filter jsonb NOT NULL DEFAULT '{}'::jsonb,
                prices_include_vat boolean NOT NULL DEFAULT false,
                currency varchar(3) NOT NULL DEFAULT 'GBP',
                default_margin_pct numeric(6,2) NOT NULL DEFAULT 15,
                change_threshold_pct numeric(6,2) NOT NULL DEFAULT 10,
                update_lead_times boolean NOT NULL DEFAULT true,
                sync_hours integer NOT NULL DEFAULT 24 CHECK (sync_hours BETWEEN 1 AND 168),
                is_active boolean NOT NULL DEFAULT true,
                last_synced_at timestamptz,
                last_status varchar(16) CHECK (last_status IS NULL OR last_status IN ('ok', 'error', 'running')),
                last_error text,
                last_summary jsonb,
                -- ready for the supplier portal / bidding (not used yet)
                portal_enabled boolean NOT NULL DEFAULT false,
                contact_email varchar(254),
                created_at timestamptz NOT NULL DEFAULT NOW(),
                updated_at timestamptz NOT NULL DEFAULT NOW()
            )
        ]])
        db.query([[
            CREATE TABLE IF NOT EXISTS shop_supplier_items (
                id serial PRIMARY KEY,
                uuid varchar(64) NOT NULL UNIQUE,
                namespace_id integer NOT NULL REFERENCES namespaces(id) ON DELETE CASCADE,
                supplier_id integer NOT NULL REFERENCES shop_suppliers(id) ON DELETE CASCADE,
                supplier_sku varchar(120) NOT NULL,
                mpn varchar(120),
                ean varchar(32),
                name text NOT NULL,
                brand varchar(120),
                category varchar(255),
                cost_minor integer NOT NULL CHECK (cost_minor > 0),
                previous_cost_minor integer,
                rrp_minor integer,
                currency varchar(3) NOT NULL DEFAULT 'GBP',
                stock_qty integer,
                in_stock boolean,
                lead_time_days integer,
                url text,
                is_active boolean NOT NULL DEFAULT true,
                first_seen_at timestamptz NOT NULL DEFAULT NOW(),
                last_seen_at timestamptz NOT NULL DEFAULT NOW(),
                cost_changed_at timestamptz,
                updated_at timestamptz NOT NULL DEFAULT NOW(),
                UNIQUE (supplier_id, supplier_sku)
            )
        ]])
        db.query([[CREATE INDEX IF NOT EXISTS shop_supplier_items_mpn_idx ON shop_supplier_items (namespace_id, lower(mpn))]])
        db.query([[
            CREATE TABLE IF NOT EXISTS shop_supplier_price_history (
                id bigserial PRIMARY KEY,
                supplier_item_id integer NOT NULL REFERENCES shop_supplier_items(id) ON DELETE CASCADE,
                day date NOT NULL,
                cost_minor integer NOT NULL,
                stock_qty integer,
                recorded_at timestamptz NOT NULL DEFAULT NOW(),
                UNIQUE (supplier_item_id, day)
            )
        ]])
    end,

    -- [2] product/category pricing + price changes --------------------------------------------
    [2] = function()
        db.query([[ALTER TABLE shop_products ADD COLUMN IF NOT EXISTS pricing_source varchar(16) NOT NULL DEFAULT 'manual']])
        db.query([[ALTER TABLE shop_products ADD COLUMN IF NOT EXISTS margin_pct numeric(6,2)]])
        db.query([[ALTER TABLE shop_products ADD COLUMN IF NOT EXISTS supplier_item_id integer
                   REFERENCES shop_supplier_items(id) ON DELETE SET NULL]])
        db.query([[ALTER TABLE shop_categories ADD COLUMN IF NOT EXISTS margin_pct numeric(6,2)]])
        db.query([[
            CREATE TABLE IF NOT EXISTS shop_price_changes (
                id serial PRIMARY KEY,
                uuid varchar(64) NOT NULL UNIQUE,
                namespace_id integer NOT NULL REFERENCES namespaces(id) ON DELETE CASCADE,
                product_id integer NOT NULL REFERENCES shop_products(id) ON DELETE CASCADE,
                supplier_item_id integer REFERENCES shop_supplier_items(id) ON DELETE SET NULL,
                old_price_minor integer NOT NULL,
                new_price_minor integer NOT NULL,
                cost_minor integer NOT NULL,
                margin_pct numeric(6,2) NOT NULL,
                change_pct numeric(8,2),
                status varchar(16) NOT NULL CHECK (status IN ('applied', 'pending', 'approved', 'rejected', 'superseded')),
                decided_by varchar(255),
                decided_at timestamptz,
                created_at timestamptz NOT NULL DEFAULT NOW()
            )
        ]])
        db.query([[CREATE INDEX IF NOT EXISTS shop_price_changes_ns_status_idx ON shop_price_changes (namespace_id, status, created_at DESC)]])
        db.query([[CREATE UNIQUE INDEX IF NOT EXISTS shop_price_changes_one_pending_uidx ON shop_price_changes (product_id)
                   WHERE status = 'pending']])
    end,

    -- [3] data model for the supplier portal and bidding (no endpoints yet) ---------------------------
    [3] = function()
        db.query([[
            CREATE TABLE IF NOT EXISTS shop_supplier_contacts (
                id serial PRIMARY KEY,
                uuid varchar(64) NOT NULL UNIQUE,
                supplier_id integer NOT NULL REFERENCES shop_suppliers(id) ON DELETE CASCADE,
                email varchar(254) NOT NULL,
                name varchar(255),
                role varchar(16) NOT NULL DEFAULT 'bidder' CHECK (role IN ('admin', 'bidder', 'viewer')),
                is_active boolean NOT NULL DEFAULT true,
                last_login_at timestamptz,
                created_at timestamptz NOT NULL DEFAULT NOW(),
                UNIQUE (supplier_id, email)
            )
        ]])
        db.query([[
            CREATE TABLE IF NOT EXISTS shop_supplier_bids (
                id serial PRIMARY KEY,
                uuid varchar(64) NOT NULL UNIQUE,
                namespace_id integer NOT NULL REFERENCES namespaces(id) ON DELETE CASCADE,
                supplier_id integer NOT NULL REFERENCES shop_suppliers(id) ON DELETE CASCADE,
                contact_id integer REFERENCES shop_supplier_contacts(id) ON DELETE SET NULL,
                quote_id integer REFERENCES shop_quotes(id) ON DELETE SET NULL,
                product_id integer REFERENCES shop_products(id) ON DELETE SET NULL,
                qty integer NOT NULL DEFAULT 1,
                unit_cost_minor integer NOT NULL,
                lead_time_days integer,
                valid_until timestamptz,
                notes text,
                status varchar(16) NOT NULL DEFAULT 'submitted'
                    CHECK (status IN ('submitted', 'accepted', 'rejected', 'withdrawn', 'expired')),
                created_at timestamptz NOT NULL DEFAULT NOW(),
                updated_at timestamptz NOT NULL DEFAULT NOW()
            )
        ]])
    end,
}
