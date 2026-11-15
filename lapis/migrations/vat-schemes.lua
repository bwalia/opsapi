--[[
    Less common VAT schemes (VAT plan phase 10).
    1. vat_attribution on the line tables: how a purchase is used under partial
       exemption ('taxable' | 'exempt' | 'residual'; NULL = residual).
    2. vat_adjustments: type 'cgs' (capital goods scheme), linked to a capital item.
    3. vat_capital_items: land, buildings, ships and aircraft in the capital goods scheme.
    4. vat_group_members: workspaces in a VAT group, joined by invitation code.
    5. invoices.customer_vat_number (EC Sales List; a customer's EU VAT number).
    Keys zz_vat_schemes_* sort after zz_vat_records_* and zz_vat_returns_*, but every
    step still checks its tables exist. Idempotent.
]]

local db = require("lapis.db")

local function table_exists(name)
    local r = db.query("SELECT to_regclass(?) IS NOT NULL AS ok", "public." .. name)
    return r and r[1] and (r[1].ok == true or r[1].ok == "t")
end

return {
    [1] = function()
        for _, t in ipairs({ "tax_transactions", "accounting_bank_transactions", "accounting_expenses" }) do
            if table_exists(t) then
                db.query("ALTER TABLE " .. t .. " ADD COLUMN IF NOT EXISTS vat_attribution VARCHAR(10)")
            end
        end
    end,
    [2] = function()
        if not table_exists("vat_adjustments") then return end
        db.query("ALTER TABLE vat_adjustments DROP CONSTRAINT IF EXISTS vat_adjustments_type_check")
        db.query([[ALTER TABLE vat_adjustments ADD CONSTRAINT vat_adjustments_type_check
            CHECK (type IN ('fuel_scale', 'bad_debt_relief', 'correction', 'cgs', 'pe_annual'))]])
        db.query("ALTER TABLE vat_adjustments ADD COLUMN IF NOT EXISTS capital_item_id INTEGER")
        db.query("ALTER TABLE vat_adjustments ADD COLUMN IF NOT EXISTS interval_no INTEGER")
    end,
    [3] = function()
        if not table_exists("vat_registrations") then return end
        db.query([[
            CREATE TABLE IF NOT EXISTS vat_capital_items (
                id SERIAL PRIMARY KEY,
                uuid VARCHAR(255) UNIQUE NOT NULL DEFAULT gen_random_uuid()::text,
                registration_id INTEGER NOT NULL REFERENCES vat_registrations(id) ON DELETE CASCADE,
                description TEXT NOT NULL,
                kind VARCHAR(20) NOT NULL CHECK (kind IN ('land', 'building', 'civil_engineering',
                    'refurbishment', 'ship', 'aircraft')),
                cost_ex_vat NUMERIC(15,2) NOT NULL,
                input_vat NUMERIC(15,2) NOT NULL,
                original_use_pct NUMERIC(5,2) NOT NULL,
                intervals INTEGER NOT NULL CHECK (intervals IN (5, 10)),
                first_used_on DATE,
                disposed_on DATE,
                created_by INTEGER,
                created_at TIMESTAMP NOT NULL DEFAULT NOW(),
                updated_at TIMESTAMP NOT NULL DEFAULT NOW()
            )
        ]])
        db.query([[CREATE INDEX IF NOT EXISTS idx_vat_capital_items_reg ON vat_capital_items (registration_id)]])
    end,
    [4] = function()
        if not table_exists("vat_registrations") then return end
        db.query([[
            CREATE TABLE IF NOT EXISTS vat_group_members (
                id SERIAL PRIMARY KEY,
                uuid VARCHAR(255) UNIQUE NOT NULL DEFAULT gen_random_uuid()::text,
                group_registration_id INTEGER NOT NULL REFERENCES vat_registrations(id) ON DELETE CASCADE,
                member_name VARCHAR(255) NOT NULL,
                invite_code VARCHAR(64) NOT NULL,
                member_namespace_id INTEGER,
                status VARCHAR(10) NOT NULL DEFAULT 'pending' CHECK (status IN ('pending', 'active', 'removed')),
                created_by INTEGER,
                joined_by INTEGER,
                joined_at TIMESTAMP,
                created_at TIMESTAMP NOT NULL DEFAULT NOW(),
                updated_at TIMESTAMP NOT NULL DEFAULT NOW()
            )
        ]])
        db.query([[CREATE UNIQUE INDEX IF NOT EXISTS idx_vat_group_members_code ON vat_group_members (invite_code)]])
        -- A workspace is in at most one VAT group at a time.
        db.query([[CREATE UNIQUE INDEX IF NOT EXISTS idx_vat_group_members_one_group
            ON vat_group_members (member_namespace_id) WHERE status = 'active']])
    end,
    [5] = function()
        if table_exists("invoices") then
            db.query("ALTER TABLE invoices ADD COLUMN IF NOT EXISTS customer_vat_number VARCHAR(30)")
        end
    end,
}
