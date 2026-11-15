--[[
    VAT on our own invoices (VAT plan phase 9).
    1. invoice_line_items.vat_code (exempt / outside the scope / reverse charge can't
       be told from a 0% rate) and invoices.tax_point (when it differs from the date).
    2. vat_registrations.sales_from ('auto' | 'invoices' | 'bank'): where a
       workspace's sales come from on its VAT return; and business_address, which a
       VAT invoice must show.
    Skips tables a deployment doesn't have. Idempotent.
]]

local db = require("lapis.db")

local function table_exists(name)
    local r = db.query("SELECT to_regclass(?) IS NOT NULL AS ok", "public." .. name)
    return r and r[1] and (r[1].ok == true or r[1].ok == "t")
end

return {
    [1] = function()
        if table_exists("invoice_line_items") then
            db.query("ALTER TABLE invoice_line_items ADD COLUMN IF NOT EXISTS vat_code VARCHAR(20)")
        end
        if table_exists("invoices") then
            db.query("ALTER TABLE invoices ADD COLUMN IF NOT EXISTS tax_point DATE")
        end
    end,
    [2] = function()
        if not table_exists("vat_registrations") then return end
        db.query([[ALTER TABLE vat_registrations
            ADD COLUMN IF NOT EXISTS sales_from VARCHAR(10) NOT NULL DEFAULT 'auto']])
        db.query("ALTER TABLE vat_registrations ADD COLUMN IF NOT EXISTS business_address TEXT")
    end,
}
