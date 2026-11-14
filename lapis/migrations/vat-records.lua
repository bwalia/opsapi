--[[
    VAT records (VAT plan phase 1, docs/plans/VAT_MTD.md).

    1. vat_registrations  — a VAT-registered business: VRN, scheme, flat-rate %,
       limited-cost trader, stagger, partial exemption. One active registration per
       business: a person (tax_copilot: many sole traders share one namespace) or a
       whole namespace (accounting: the namespace is the business, user_id NULL).
    2. vat_rules          — supplier / description / category -> VAT code, either the
       business's own (registration_id) or global (registration_id NULL, seeded).
       A business's rules never affect another business.
    3. tax_transactions   — VAT fields per bank line (code, net, VAT, notional VAT for
       reverse charge / postponed import VAT, reclaimable %, period, evidence, who
       decided and why). net + VAT = amount is checked for new rows.
    4. accounting_expenses / accounting_bank_transactions — the same VAT fields where
       those tables exist (the accounting feature may be off).
    Idempotent: every step checks before it creates.
]]

local db = require("lapis.db")

local function table_exists(name)
    local r = db.query("SELECT to_regclass(?) IS NOT NULL AS ok", "public." .. name)
    return r and r[1] and (r[1].ok == true or r[1].ok == "t")
end

local function constraint_exists(name)
    local r = db.query("SELECT 1 FROM pg_constraint WHERE conname = ?", name)
    return r and #r > 0
end

-- The VAT fields a transaction-like table carries.
local function add_vat_columns(tbl)
    for _, col in ipairs({
        "vat_code VARCHAR(20)",
        "net_amount NUMERIC(15,2)",
        "vat_notional NUMERIC(15,2)",            -- reverse charge / postponed import VAT
        "vat_reclaimable_pct NUMERIC(5,2)",
        "vat_period_key VARCHAR(10)",
        "vat_evidence JSONB",                    -- { has_receipt, supplier_vrn, document_url }
        "vat_source VARCHAR(10)",                -- rule | ai | user
        "vat_confidence NUMERIC(5,4)",
        "vat_reason TEXT",
        "vat_rule_id INTEGER",
        "vat_registration_id INTEGER",
        "vat_decided_by INTEGER",
        "vat_decided_at TIMESTAMP",
    }) do
        db.query("ALTER TABLE " .. tbl .. " ADD COLUMN IF NOT EXISTS " .. col)
    end
    -- vat_amount already exists on the accounting tables; add it where missing.
    db.query("ALTER TABLE " .. tbl .. " ADD COLUMN IF NOT EXISTS vat_amount NUMERIC(15,2)")
    db.query("CREATE INDEX IF NOT EXISTS idx_" .. tbl .. "_vat_period ON " .. tbl
        .. " (vat_registration_id, vat_period_key)")
end

-- Global starting rules: the obvious UK cases. A business's own rule always wins.
local SEED_RULES = {
    { "contains", "HMRC", "OUTSIDE", nil, "Payments to HMRC are tax, not a purchase." },
    { "contains", "COUNCIL TAX", "OUTSIDE", nil, "Council tax is not a supply, so no VAT." },
    { "contains", "CTAX", "OUTSIDE", nil, "Council tax is not a supply, so no VAT." },
    { "contains", "BUSINESS RATES", "OUTSIDE", nil, "Business rates are not a supply, so no VAT." },
    { "contains", "SALARY", "OUTSIDE", nil, "Wages are not a supply, so no VAT." },
    { "contains", "PAYROLL", "OUTSIDE", nil, "Wages are not a supply, so no VAT." },
    { "contains", "TRANSFER TO", "OUTSIDE", nil, "Moving your own money is not a supply." },
    { "contains", "TRANSFER FROM", "OUTSIDE", nil, "Moving your own money is not a supply." },
    { "contains", "INSURANCE", "EXEMPT", nil, "Insurance is exempt from VAT (Insurance Premium Tax instead)." },
    { "contains", "BANK CHARGE", "EXEMPT", nil, "Bank charges for financial services are exempt." },
    { "contains", "ACCOUNT FEE", "EXEMPT", nil, "Bank account fees are exempt financial services." },
    { "contains", "INTEREST", "EXEMPT", nil, "Interest is exempt from VAT." },
    { "contains", "ROYAL MAIL", "EXEMPT", nil, "Royal Mail stamps are exempt postal services." },
    { "contains", "TRAINLINE", "ZERO", nil, "Passenger rail travel is zero-rated." },
    { "contains", "TFL", "ZERO", nil, "Passenger transport is zero-rated." },
    { "category", "loan_repayments", "OUTSIDE", nil, "Loan repayments are not a supply." },
    { "category", "tax_payments", "OUTSIDE", nil, "Tax payments are not a supply." },
    { "category", "transfer", "OUTSIDE", nil, "Moving your own money is not a supply." },
    { "category", "personal_expense", "OUTSIDE", nil, "Personal spending is not a business purchase." },
    { "category", "drawings", "OUTSIDE", nil, "Drawings are not a business purchase." },
    { "category", "salaries_wages", "OUTSIDE", nil, "Wages are not a supply, so no VAT." },
    { "category", "business_rates", "OUTSIDE", nil, "Business rates are not a supply, so no VAT." },
    { "category", "premises_insurance", "EXEMPT", nil, "Insurance is exempt from VAT." },
    { "category", "business_insurance", "EXEMPT", nil, "Insurance is exempt from VAT." },
    { "category", "bank_charges", "EXEMPT", nil, "Bank charges are exempt financial services." },
    { "category", "rental_income", "EXEMPT", nil,
      "Residential rent is exempt. Commercial rent is exempt unless you opted to tax the building — "
          .. "add your own rule if you did." },
    { "category", "client_entertainment", "STD20", 0,
      "VAT on business entertainment can't be reclaimed." },
}

return {
    [1] = function()
        db.query([[
            CREATE TABLE IF NOT EXISTS vat_registrations (
                id SERIAL PRIMARY KEY,
                uuid VARCHAR(255) UNIQUE NOT NULL DEFAULT gen_random_uuid()::text,
                namespace_id INTEGER NOT NULL,
                user_id INTEGER,
                business_name VARCHAR(255),
                vrn VARCHAR(9) NOT NULL,
                effective_date DATE,
                scheme VARCHAR(20) NOT NULL DEFAULT 'standard'
                    CHECK (scheme IN ('standard', 'cash', 'flat_rate', 'annual')),
                flat_rate_pct NUMERIC(5,2),
                flat_rate_first_year BOOLEAN NOT NULL DEFAULT false,
                limited_cost_trader BOOLEAN NOT NULL DEFAULT false,
                stagger VARCHAR(20) NOT NULL DEFAULT 'quarterly_mar'
                    CHECK (stagger IN ('quarterly_mar', 'quarterly_apr', 'quarterly_may', 'monthly', 'annual')),
                partially_exempt BOOLEAN NOT NULL DEFAULT false,
                recovery_pct NUMERIC(5,2),
                status VARCHAR(20) NOT NULL DEFAULT 'active' CHECK (status IN ('active', 'deregistered')),
                created_by INTEGER,
                created_at TIMESTAMP NOT NULL DEFAULT NOW(),
                updated_at TIMESTAMP NOT NULL DEFAULT NOW()
            )
        ]])
        -- One active registration per business (a person, or the namespace when user_id is NULL).
        db.query([[CREATE UNIQUE INDEX IF NOT EXISTS uq_vat_registrations_active
            ON vat_registrations (namespace_id, COALESCE(user_id, 0)) WHERE status = 'active']])
        db.query("CREATE INDEX IF NOT EXISTS idx_vat_registrations_vrn ON vat_registrations (vrn)")
    end,

    [2] = function()
        db.query([[
            CREATE TABLE IF NOT EXISTS vat_rules (
                id SERIAL PRIMARY KEY,
                uuid VARCHAR(255) UNIQUE NOT NULL DEFAULT gen_random_uuid()::text,
                registration_id INTEGER REFERENCES vat_registrations(id) ON DELETE CASCADE,
                match_type VARCHAR(20) NOT NULL CHECK (match_type IN ('merchant', 'contains', 'category')),
                match_value VARCHAR(255) NOT NULL,
                vat_code VARCHAR(20) NOT NULL,
                reclaimable_pct NUMERIC(5,2),
                reason TEXT,
                source VARCHAR(10) NOT NULL DEFAULT 'user' CHECK (source IN ('seed', 'user', 'learned')),
                hits INTEGER NOT NULL DEFAULT 0,
                is_active BOOLEAN NOT NULL DEFAULT true,
                created_by INTEGER,
                created_at TIMESTAMP NOT NULL DEFAULT NOW(),
                updated_at TIMESTAMP NOT NULL DEFAULT NOW()
            )
        ]])
        db.query([[CREATE UNIQUE INDEX IF NOT EXISTS uq_vat_rules_match
            ON vat_rules (COALESCE(registration_id, 0), match_type, lower(match_value))]])
        for _, r in ipairs(SEED_RULES) do
            db.query([[INSERT INTO vat_rules (registration_id, match_type, match_value, vat_code,
                    reclaimable_pct, reason, source)
                SELECT NULL, ?, ?, ?, ?, ?, 'seed'
                WHERE NOT EXISTS (SELECT 1 FROM vat_rules WHERE registration_id IS NULL
                    AND match_type = ? AND lower(match_value) = lower(?))]],
                r[1], r[2], r[3], r[4] or db.NULL, r[5], r[1], r[2])
        end
    end,

    [3] = function()
        if not table_exists("tax_transactions") then return end
        add_vat_columns("tax_transactions")
        -- net + VAT must make the amount (1p tolerance). NOT VALID: checks new and
        -- changed rows only, so existing data is untouched.
        if not constraint_exists("ck_tax_transactions_vat_split") then
            db.query([[ALTER TABLE tax_transactions ADD CONSTRAINT ck_tax_transactions_vat_split
                CHECK (vat_code IS NULL OR net_amount IS NULL
                    OR abs(net_amount + COALESCE(vat_amount, 0) - amount) <= 0.01) NOT VALID]])
        end
    end,

    [4] = function()
        for _, t in ipairs({ "accounting_expenses", "accounting_bank_transactions" }) do
            if table_exists(t) then add_vat_columns(t) end
        end
    end,
}
