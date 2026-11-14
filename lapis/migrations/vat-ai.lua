--[[
    AI VAT coding that learns (VAT plan phase 3, docs/plans/VAT_MTD.md).

    1. Review flags on VAT-coded lines: vat_review + vat_review_reasons (why a person
       must look), on tax_transactions and, where present, the accounting tables.
    2. vat_rule_candidates: a supplier -> VAT code that several businesses each
       taught us. A platform admin may promote one to a global rule; nothing is
       promoted automatically (one business must never change another's VAT).
    3. vat_eval_runs: accuracy of the live model on the labelled set
       (lib/data/vat-eval.json), so every change can be measured.
    4. Adds any new global starting rules (lib/vat-seed-rules.lua) missing from the
       table, e.g. congestion charge, MOT, DVLA, opted-to-tax rent, tenant deposits.
    Idempotent.
]]

local db = require("lapis.db")

local function table_exists(name)
    local r = db.query("SELECT to_regclass(?) IS NOT NULL AS ok", "public." .. name)
    return r and r[1] and (r[1].ok == true or r[1].ok == "t")
end

return {
    [1] = function()
        for _, t in ipairs({ "tax_transactions", "accounting_expenses", "accounting_bank_transactions" }) do
            if table_exists(t) then
                db.query("ALTER TABLE " .. t .. " ADD COLUMN IF NOT EXISTS vat_review BOOLEAN NOT NULL DEFAULT false")
                db.query("ALTER TABLE " .. t .. " ADD COLUMN IF NOT EXISTS vat_review_reasons JSONB")
            end
        end
    end,

    [2] = function()
        db.query([[
            CREATE TABLE IF NOT EXISTS vat_rule_candidates (
                id SERIAL PRIMARY KEY,
                uuid VARCHAR(255) UNIQUE NOT NULL DEFAULT gen_random_uuid()::text,
                match_type VARCHAR(20) NOT NULL,
                match_value VARCHAR(255) NOT NULL,
                vat_code VARCHAR(20) NOT NULL,
                reclaimable_pct NUMERIC(5,2),
                businesses INTEGER NOT NULL DEFAULT 1,
                status VARCHAR(20) NOT NULL DEFAULT 'pending' CHECK (status IN ('pending', 'promoted', 'dismissed')),
                decided_by INTEGER,
                decided_at TIMESTAMP,
                created_at TIMESTAMP NOT NULL DEFAULT NOW(),
                updated_at TIMESTAMP NOT NULL DEFAULT NOW()
            )
        ]])
        db.query([[CREATE UNIQUE INDEX IF NOT EXISTS uq_vat_rule_candidates
            ON vat_rule_candidates (match_type, lower(match_value), vat_code)]])
    end,

    [3] = function()
        db.query([[
            CREATE TABLE IF NOT EXISTS vat_eval_runs (
                id SERIAL PRIMARY KEY,
                status VARCHAR(20) NOT NULL DEFAULT 'running',
                model VARCHAR(255),
                lines INTEGER,
                accuracy NUMERIC(5,4),
                pct_accuracy NUMERIC(5,4),
                review_rate NUMERIC(5,4),
                model_call_rate NUMERIC(5,4),
                stats JSONB,
                mistakes JSONB,
                error TEXT,
                started_by INTEGER,
                started_at TIMESTAMP NOT NULL DEFAULT NOW(),
                finished_at TIMESTAMP
            )
        ]])
    end,

    [4] = function()
        if not table_exists("vat_rules") then return end
        for _, r in ipairs(require("lib.vat-seed-rules")) do
            db.query([[INSERT INTO vat_rules (registration_id, match_type, match_value, vat_code,
                    reclaimable_pct, reason, source)
                SELECT NULL, ?, ?, ?, ?, ?, 'seed'
                WHERE NOT EXISTS (SELECT 1 FROM vat_rules WHERE registration_id IS NULL
                    AND match_type = ? AND lower(match_value) = lower(?))]],
                r[1], r[2], r[3], r[4] or db.NULL, r[5], r[1], r[2])
        end
    end,
}
