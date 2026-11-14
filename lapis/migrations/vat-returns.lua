--[[
    VAT returns (VAT plan phase 2, docs/plans/VAT_MTD.md).

    1. vat_returns     — a return for a business (vat_registrations) and period: the 9
       boxes, pay/repay, the calculation (warnings, notes, per-box audit trail) and,
       from phase 4, HMRC's period key and receipt. One draft per period; a
       submitted return is never changed.
    2. vat_adjustments — entries that aren't bank lines: fuel scale charges, bad debt
       relief, and corrections of earlier errors (applied only within HMRC's limit).
    Idempotent.
]]

local db = require("lapis.db")

return {
    [1] = function()
        db.query([[
            CREATE TABLE IF NOT EXISTS vat_returns (
                id SERIAL PRIMARY KEY,
                uuid VARCHAR(255) UNIQUE NOT NULL DEFAULT gen_random_uuid()::text,
                registration_id INTEGER NOT NULL REFERENCES vat_registrations(id) ON DELETE CASCADE,
                namespace_id INTEGER NOT NULL,
                period_start DATE NOT NULL,
                period_end DATE NOT NULL,
                period_key VARCHAR(10),
                due_date DATE,
                scheme VARCHAR(20) NOT NULL,
                status VARCHAR(20) NOT NULL DEFAULT 'draft'
                    CHECK (status IN ('draft', 'submitting', 'submitted', 'failed')),
                box1 NUMERIC(15,2) NOT NULL DEFAULT 0,
                box2 NUMERIC(15,2) NOT NULL DEFAULT 0,
                box3 NUMERIC(15,2) NOT NULL DEFAULT 0,
                box4 NUMERIC(15,2) NOT NULL DEFAULT 0,
                box5 NUMERIC(15,2) NOT NULL DEFAULT 0,
                box6 NUMERIC(15,0) NOT NULL DEFAULT 0,
                box7 NUMERIC(15,0) NOT NULL DEFAULT 0,
                box8 NUMERIC(15,0) NOT NULL DEFAULT 0,
                box9 NUMERIC(15,0) NOT NULL DEFAULT 0,
                direction VARCHAR(10),
                line_count INTEGER NOT NULL DEFAULT 0,
                uncoded_count INTEGER NOT NULL DEFAULT 0,
                calculation JSONB,
                hmrc_receipt JSONB,
                created_by INTEGER,
                submitted_by INTEGER,
                submitted_at TIMESTAMP,
                created_at TIMESTAMP NOT NULL DEFAULT NOW(),
                updated_at TIMESTAMP NOT NULL DEFAULT NOW(),
                CHECK (period_end >= period_start)
            )
        ]])
        db.query([[CREATE UNIQUE INDEX IF NOT EXISTS uq_vat_returns_draft
            ON vat_returns (registration_id, period_start, period_end) WHERE status = 'draft']])
        db.query([[CREATE UNIQUE INDEX IF NOT EXISTS uq_vat_returns_submitted
            ON vat_returns (registration_id, period_start, period_end) WHERE status IN ('submitting', 'submitted')]])
        db.query([[CREATE INDEX IF NOT EXISTS idx_vat_returns_registration
            ON vat_returns (registration_id, period_end DESC)]])
    end,

    [2] = function()
        db.query([[
            CREATE TABLE IF NOT EXISTS vat_adjustments (
                id SERIAL PRIMARY KEY,
                uuid VARCHAR(255) UNIQUE NOT NULL DEFAULT gen_random_uuid()::text,
                registration_id INTEGER NOT NULL REFERENCES vat_registrations(id) ON DELETE CASCADE,
                period_start DATE NOT NULL,
                period_end DATE NOT NULL,
                type VARCHAR(20) NOT NULL CHECK (type IN ('fuel_scale', 'bad_debt_relief', 'correction')),
                description TEXT,
                vat NUMERIC(15,2),
                net NUMERIC(15,2),
                box1 NUMERIC(15,2),
                box4 NUMERIC(15,2),
                due_date DATE,
                written_off BOOLEAN NOT NULL DEFAULT false,
                created_by INTEGER,
                created_at TIMESTAMP NOT NULL DEFAULT NOW(),
                updated_at TIMESTAMP NOT NULL DEFAULT NOW()
            )
        ]])
        db.query([[CREATE INDEX IF NOT EXISTS idx_vat_adjustments_period
            ON vat_adjustments (registration_id, period_start, period_end)]])
    end,
}
