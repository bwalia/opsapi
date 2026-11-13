-- luacheck: max line length 140
--[[
    Payment methods ("Getting paid") + invoice PO number / payment method
    ======================================================================

    [1] namespace_payment_methods (core): how a workspace gets paid — bank accounts (bank transfer), card,
        cheque, other. One default per namespace (partial unique index). Printed as "How to pay" on Order
        Authorisations, bank-transfer shop orders and invoices (show_on_documents).
    [2] invoices.po_number (the customer's purchase order number) and invoices.payment_method_uuid
        (null = the namespace's default bank account). Rides on FEATURES.INVOICING like the invoices table.

    Registered in migrations.lua as zzpm1 ([1], core) and zzpm2 ([2], invoicing). Idempotent.
]]

local db = require("lapis.db")

local function table_exists(name)
    local r = db.query("SELECT to_regclass(?) IS NOT NULL AS ok", "public." .. name)
    return r and r[1] and r[1].ok
end

return {
    [1] = function()
        db.query([[
            CREATE TABLE IF NOT EXISTS namespace_payment_methods (
                id serial PRIMARY KEY,
                uuid varchar(64) NOT NULL UNIQUE,
                namespace_id integer NOT NULL REFERENCES namespaces(id) ON DELETE CASCADE,
                kind varchar(24) NOT NULL DEFAULT 'bank_transfer'
                    CHECK (kind IN ('bank_transfer', 'card', 'cheque', 'other')),
                label varchar(120) NOT NULL,
                account_name varchar(160),
                bank_name varchar(120),
                sort_code varchar(8),
                account_number varchar(16),
                iban varchar(34),
                swift_bic varchar(11),
                currency varchar(3) NOT NULL DEFAULT 'GBP',
                instructions text,
                is_default boolean NOT NULL DEFAULT false,
                show_on_documents boolean NOT NULL DEFAULT true,
                is_active boolean NOT NULL DEFAULT true,
                sort_order integer NOT NULL DEFAULT 0,
                created_by varchar(64),
                created_at timestamp NOT NULL DEFAULT NOW(),
                updated_at timestamp NOT NULL DEFAULT NOW()
            )
        ]])
        db.query([[CREATE INDEX IF NOT EXISTS idx_ns_payment_methods_ns
                   ON namespace_payment_methods (namespace_id, is_active, sort_order)]])
        db.query([[CREATE UNIQUE INDEX IF NOT EXISTS idx_ns_payment_methods_one_default
                   ON namespace_payment_methods (namespace_id) WHERE is_default]])
    end,
    [2] = function()
        if not table_exists("invoices") then return end
        db.query([[
            ALTER TABLE invoices
                ADD COLUMN IF NOT EXISTS po_number varchar(64),
                ADD COLUMN IF NOT EXISTS payment_method_uuid varchar(64)
        ]])
    end,
}
