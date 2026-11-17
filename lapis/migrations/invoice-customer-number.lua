-- luacheck: max line length 140
--[[
    Customer invoice number (FEATURES.INVOICING)
    ============================================

    invoices.invoice_number (INV-0001, …) stays the internal, sequential number. customer_invoice_number is the
    number the customer sees (PDF, email, e-invoice, shop order page). It defaults to invoice_number; staff may
    set their own while the invoice is a draft (queries/InvoiceQueries.lua).

    [1] the column, backfilled from invoice_number; a BEFORE INSERT trigger fills it in for every way an invoice
        is created (manual, from a timesheet, shop order, field service job, …); a case-insensitive unique index
        per workspace over live invoices. The index is skipped (with a warning) if existing data already clashes,
        and the application check still applies.

    Registered in migrations.lua as zzinvc1. Idempotent.
]]

local db = require("lapis.db")

return {
    [1] = function()
        db.query("ALTER TABLE invoices ADD COLUMN IF NOT EXISTS customer_invoice_number varchar(64)")
        db.query([[UPDATE invoices SET customer_invoice_number = invoice_number
                    WHERE customer_invoice_number IS NULL AND invoice_number IS NOT NULL]])
        db.query([[
            CREATE OR REPLACE FUNCTION invoices_default_customer_number() RETURNS trigger AS $$
            BEGIN
                IF NEW.customer_invoice_number IS NULL OR btrim(NEW.customer_invoice_number) = '' THEN
                    NEW.customer_invoice_number := NEW.invoice_number;
                END IF;
                RETURN NEW;
            END;
            $$ LANGUAGE plpgsql
        ]])
        db.query("DROP TRIGGER IF EXISTS invoices_default_customer_number ON invoices")
        db.query([[CREATE TRIGGER invoices_default_customer_number BEFORE INSERT ON invoices
                   FOR EACH ROW EXECUTE FUNCTION invoices_default_customer_number()]])
        -- Checked first rather than caught: a failed statement would abort the migration's transaction.
        local dup = db.query([[SELECT 1 FROM invoices WHERE deleted_at IS NULL AND customer_invoice_number IS NOT NULL
                                GROUP BY namespace_id, lower(customer_invoice_number) HAVING COUNT(*) > 1 LIMIT 1]])[1]
        if dup then
            print("[migrations] invoices_customer_number_uniq skipped: existing invoices share a number")
        else
            db.query([[
                CREATE UNIQUE INDEX IF NOT EXISTS invoices_customer_number_uniq
                    ON invoices (namespace_id, lower(customer_invoice_number))
                 WHERE deleted_at IS NULL AND customer_invoice_number IS NOT NULL
            ]])
        end
    end,
}
