--[[
  Income Types — admin-managed catalogue of income sources.

  Replaces the hard-coded VALID_INCOME_TYPES list that used to live in
  routes/my-incomes.lua. Each row is one selectable income source (Salary,
  Rental, Dividends, …). Admins CRUD these via routes/tax-admin-income-types.lua;
  the catalogue is then the single source of truth for:
    - the /api/v2/tax/my-incomes/types dropdown + create/update validation
    - the onboarding income questionnaire (later phase)
    - per-type document requirements + AI extraction rules (later phases)

  FastAPI maps this table read-only via backend/app/models/income_type.py
  (mirrors the ClassificationProfile / classification_profiles split: the
  table is owned by this Lapis migration, Python never creates it).

  Soft enable/disable is via is_active (not hard DELETE) so historical
  my_incomes rows that reference a now-retired key stay reproducible.

  Pattern: mirrors my-income-system.lua (table + index strategy) and the
  classification_profiles catalogue (admin-managed, JSONB rule columns).
]]

local schema = require("lapis.db.schema")
local types = schema.types
local db = require("lapis.db")
local cjson = require("cjson")
local Global = require("helper.global")

-- Canonical seed set — mirrors the labels the frontend already shows so the
-- My Income dropdown is byte-for-byte unchanged after the rewire. Document
-- lists + AI/HMRC columns are placeholders consumed by later phases; they are
-- inert data in Phase 1.
local SEED = {
    {
        key = "salary",
        label = "Salary / Employment (PAYE)",
        description = "Wages or salary from employment, taxed through PAYE.",
        order = 10,
        docs = {
            { key = "p60",      label = "P60 end-of-year certificate", required = false },
            { key = "p45",      label = "P45 (if you left a job)",     required = false },
            { key = "payslips", label = "Payslips",                    required = false },
        },
    },
    {
        key = "self_employment",
        label = "Self-employment / Sole trader",
        description = "Income from your trade as a sole trader or self-employed individual.",
        order = 20,
        docs = {
            { key = "bank_statements", label = "Business bank statements", required = false },
            { key = "sales_invoices",  label = "Sales invoices",           required = false },
        },
    },
    {
        key = "dividends",
        label = "Dividends",
        description = "Dividend payments received from shares you own.",
        order = 30,
        docs = {
            { key = "dividend_vouchers", label = "Dividend vouchers", required = false },
        },
    },
    {
        key = "rental",
        label = "Rental / Property income",
        description = "Rent received from letting out property.",
        order = 40,
        docs = {
            { key = "rental_statements", label = "Rental / letting statements",   required = false },
            { key = "tenancy_agreement", label = "Lease / tenancy agreement",      required = false },
        },
    },
    {
        key = "interest",
        label = "Bank interest",
        description = "Interest earned on bank or building society accounts.",
        order = 50,
        docs = {
            { key = "interest_certificate", label = "Interest certificate", required = false },
            { key = "bank_statements",      label = "Bank statements",      required = false },
        },
    },
    {
        key = "pension",
        label = "Pension income",
        description = "Income drawn from a pension.",
        order = 60,
        docs = {
            { key = "pension_statement", label = "Pension statement / P60", required = false },
        },
    },
    {
        key = "capital_gains",
        label = "Capital gains",
        description = "Gains from selling assets such as property or shares.",
        order = 70,
        docs = {
            { key = "completion_statement", label = "Completion statement",        required = false },
            { key = "contract_notes",       label = "Contract notes (shares)",     required = false },
        },
    },
    {
        key = "other",
        label = "Other income",
        description = "Any other taxable income not covered by the categories above.",
        order = 80,
        docs = {},
    },
}

return {
    -- 1. Create income_types table
    [1] = function()
        schema.create_table("income_types", {
            { "id",                  types.serial },
            { "uuid",                types.varchar({ unique = true }) },
            -- Catalogue identity. income_type_key is the stable key stored on
            -- my_incomes.income_type; treat it as immutable after create.
            { "income_type_key",     types.varchar({ unique = true }) },
            { "display_name",        types.varchar },
            { "description",         types.text({ null = true }) },
            -- Documentation + entry behaviour (consumed by later phases)
            { "required_documents",  "jsonb NOT NULL DEFAULT '[]'::jsonb" },
            { "allows_manual_entry", types.boolean({ default = true }) },
            -- AI extraction / classification rules (consumed Phase 5)
            { "keyword_rules",       "jsonb NOT NULL DEFAULT '[]'::jsonb" },
            { "category_affinity",   "jsonb NOT NULL DEFAULT '{}'::jsonb" },
            { "rules_markdown",      types.text({ null = true }) },
            -- HMRC form/field routing (consumed Phase 7)
            { "hmrc_mapping",        "jsonb NOT NULL DEFAULT '{}'::jsonb" },
            -- Catalogue ordering + soft enable/disable
            { "display_order",       types.integer({ default = 0 }) },
            { "is_active",           types.boolean({ default = true }) },
            { "namespace_id",        types.integer({ null = true }) },
            -- Timestamps
            { "created_at",          types.time({ default = db.raw("NOW()") }) },
            { "updated_at",          types.time({ default = db.raw("NOW()") }) },
            "PRIMARY KEY (id)"
        })
        print("[Income Types] Created income_types table")
    end,

    -- 2. Add indexes to income_types
    [2] = function()
        schema.create_index("income_types", "uuid")
        schema.create_index("income_types", "income_type_key")
        schema.create_index("income_types", "is_active")
        schema.create_index("income_types", "namespace_id")
        print("[Income Types] Added indexes to income_types")
    end,

    -- 3. Seed the canonical income types (idempotent — safe on re-run and
    -- never clobbers admin edits thanks to ON CONFLICT DO NOTHING).
    [3] = function()
        for _, t in ipairs(SEED) do
            -- cjson.encode({}) emits "{}" (object); required_documents is an
            -- array column, so force "[]" when a type has no documents.
            local docs_json = (#t.docs > 0) and cjson.encode(t.docs) or "[]"
            db.query([[
                INSERT INTO income_types
                    (uuid, income_type_key, display_name, description,
                     required_documents, allows_manual_entry,
                     keyword_rules, category_affinity, rules_markdown,
                     hmrc_mapping, display_order, is_active, namespace_id,
                     created_at, updated_at)
                VALUES (?, ?, ?, ?, ?::jsonb, true,
                        '[]'::jsonb, '{}'::jsonb, NULL,
                        '{}'::jsonb, ?, true, NULL, NOW(), NOW())
                ON CONFLICT (income_type_key) DO NOTHING
            ]],
                Global.generateUUID(),
                t.key,
                t.label,
                t.description,
                docs_json,
                t.order
            )
        end
        print("[Income Types] Seeded " .. #SEED .. " canonical income types")
    end,
}
