-- luacheck: max line length 140
--[[
    Deal codes and supplier price requests (FEATURES.SHOP)
    =====================================================

    One private, random code per deal (WS-XXXX-XXXX, lib/deal-codes.lua) that links the customer side
    (CRM lead, quotes and their revisions, orders) to the supplier side (price requests, purchase orders)
    inside the CRM only. Customers never see it; suppliers see it instead of the customer.

    [1] shop_deal_codes: every code ever issued, UNIQUE(code) (a clash is retried by the generator).
        deal_code varchar(32) on shop_quotes, shop_orders, crm_leads (CRM) and purchase_orders (invoicing),
        each indexed by (namespace_id, deal_code). Settings on shop_settings: deal_code_prefix (default WS),
        deal_code_length (default 8 = XXXX-XXXX), po_deliver_to (our delivery address for supplier POs;
        unset = the "Bill to" address). Index on namespace_audit_logs for the deal's audit trail.
    [2] shop_supplier_requests: a price request to a supplier for a deal: supplier, contact, date sent,
        spec, lines [{ line_uuid, description, qty, unit_price_minor (ex VAT) }], their quote reference,
        stock / lead time, valid until, notes.
    [3] Backfill: every lead, quote and order without a code gets one (revisions share the original's,
        a quote shares its lead's, an order its quote's, a purchase order its order's). Existing POs from
        shop orders that deliver to the customer are legacy drop-ships: logged in the deal's audit trail,
        left as they are. Only fills NULLs and logs each legacy PO once, so running it again changes nothing.

    [4] A supplier's contact person (shop_suppliers.contact_name: "Hello Sam" in a price request) and how a
        request was sent (shop_supplier_requests.channel email|whatsapp|sms, message = what was sent), for
        "Ask a supplier" on the quote page (queries/ShopSupplierRequestQueries.lua).

    Registered in migrations.lua as zzs55–zzs57 and zzs65. Idempotent.
]]

local db = require("lapis.db")

local function table_exists(name)
    local r = db.query("SELECT to_regclass(?) IS NOT NULL AS ok", "public." .. name)[1]
    return r and r.ok == true
end

local function add_code_column(tbl)
    if not table_exists(tbl) then return end
    db.query("ALTER TABLE " .. tbl .. " ADD COLUMN IF NOT EXISTS deal_code varchar(32)")
    db.query("CREATE INDEX IF NOT EXISTS " .. tbl .. "_deal_code_idx ON " .. tbl
        .. " (namespace_id, deal_code) WHERE deal_code IS NOT NULL")
end

return {
    [1] = function()
        db.query([[
            CREATE TABLE IF NOT EXISTS shop_deal_codes (
                id serial PRIMARY KEY,
                namespace_id integer NOT NULL REFERENCES namespaces(id) ON DELETE CASCADE,
                code varchar(32) NOT NULL,
                created_by_user_id integer,
                created_at timestamptz NOT NULL DEFAULT NOW()
            )
        ]])
        db.query("CREATE UNIQUE INDEX IF NOT EXISTS shop_deal_codes_code_uidx ON shop_deal_codes (code)")
        db.query("CREATE INDEX IF NOT EXISTS shop_deal_codes_ns_idx ON shop_deal_codes (namespace_id, created_at DESC)")
        for _, t in ipairs({ "shop_quotes", "shop_orders", "crm_leads", "purchase_orders" }) do add_code_column(t) end
        db.query([[
            ALTER TABLE shop_settings
                ADD COLUMN IF NOT EXISTS deal_code_prefix varchar(6),
                ADD COLUMN IF NOT EXISTS deal_code_length smallint,
                ADD COLUMN IF NOT EXISTS po_deliver_to jsonb
        ]])
        if table_exists("namespace_audit_logs") then
            db.query([[CREATE INDEX IF NOT EXISTS namespace_audit_logs_entity_idx
                       ON namespace_audit_logs (namespace_id, entity_type, entity_id)]])
        end
    end,

    [2] = function()
        db.query([[
            CREATE TABLE IF NOT EXISTS shop_supplier_requests (
                id serial PRIMARY KEY,
                uuid varchar(64) NOT NULL UNIQUE,
                namespace_id integer NOT NULL REFERENCES namespaces(id) ON DELETE CASCADE,
                deal_code varchar(32) NOT NULL,
                supplier_id integer REFERENCES shop_suppliers(id) ON DELETE SET NULL,
                supplier_name varchar(255) NOT NULL,
                contact_name varchar(160),
                contact_email varchar(254),
                sent_at date,
                spec text CHECK (spec IS NULL OR char_length(spec) <= 8000),
                lines jsonb NOT NULL DEFAULT '[]'::jsonb,
                supplier_quote_ref varchar(120),
                lead_time varchar(160),
                valid_until date,
                notes text CHECK (notes IS NULL OR char_length(notes) <= 4000),
                created_by_user_id integer,
                created_at timestamptz NOT NULL DEFAULT NOW(),
                updated_at timestamptz NOT NULL DEFAULT NOW()
            )
        ]])
        db.query([[CREATE INDEX IF NOT EXISTS shop_supplier_requests_deal_idx
                   ON shop_supplier_requests (namespace_id, deal_code, created_at)]])
        db.query([[CREATE INDEX IF NOT EXISTS shop_supplier_requests_ref_idx
                   ON shop_supplier_requests (namespace_id, lower(supplier_quote_ref)) WHERE supplier_quote_ref IS NOT NULL]])
    end,

    [3] = function()
        local summary = require("queries.ShopDealQueries").backfill()
        print(("[ShopDealCodes] backfill: %d new code(s); %d lead(s), %d quote(s), %d order(s), %d PO(s) linked; "
            .. "%d legacy drop-ship PO(s) logged"):format(summary.codes, summary.leads, summary.quotes, summary.orders,
            summary.purchase_orders, summary.legacy_drop_ship))
    end,

    [4] = function()
        if table_exists("shop_suppliers") then
            db.query("ALTER TABLE shop_suppliers ADD COLUMN IF NOT EXISTS contact_name varchar(160)")
        end
        if not table_exists("shop_supplier_requests") then return end
        db.query([[ALTER TABLE shop_supplier_requests ADD COLUMN IF NOT EXISTS channel varchar(16)
                   CHECK (channel IS NULL OR channel IN ('email', 'whatsapp', 'sms'))]])
        db.query([[ALTER TABLE shop_supplier_requests ADD COLUMN IF NOT EXISTS message text
                   CHECK (message IS NULL OR char_length(message) <= 8000)]])
    end,
}
