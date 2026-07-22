--[[
  Pension Payments System — "Relief: Pension payments" (SA100 page TR4,
  boxes 1 / 1.1 / 2 / 3 / 4). Unlike rental / self-employment / overseas
  property there is NO per-entity drill-down here: payments hang straight
  off the user + tax year, grouped into admin-managed sections.

  1. pension_payment_categories : the SECTIONS of the reference screen
     ("Payments into registered schemes…", "Payments to employer
      schemes…", "Payments to eligible overseas schemes…") — an admin
     catalogue like property_line_categories, so new sections are a row
     insert, not a deploy. supports_relief_flag / supports_one_off_flag
     tell the frontend which sections show the two per-row checkboxes
     (only registered schemes on the reference form).
  2. pension_payment_items      : the user's payment rows (provider +
     description, amount, the two flags), one per payment per tax year.
     Soft-delete like property_line_items.
  3. A new income_types row makes "Pension payments (tax relief)"
     selectable in the profile questionnaire — selected_income_types
     sources its options from that catalogue, so no option seeding.

  The relief-at-source flag is what routes a registered-scheme row to
  box 1 (provider claims basic-rate relief) vs box 2 (retirement annuity
  contract, no relief at source); one_off feeds box 1.1.

  Only executed when PROJECT_CODE includes 'tax_copilot'.
]]

local schema = require("lapis.db.schema")
local types = schema.types
local db = require("lapis.db")
local cjson = require("cjson")
local MigrationUtils = require "helper.migration-utils"

return {
    -- =========================================================================
    -- 1. pension_payment_categories (admin catalogue — the form's sections)
    -- =========================================================================
    [1] = function()
        schema.create_table("pension_payment_categories", {
            { "id",                  types.serial },
            { "uuid",                types.varchar({ unique = true }) },
            { "namespace_id",        types.integer({ null = true }) },
            { "category_key",        types.varchar({ unique = true }) },  -- stable key, e.g. 'pp_registered_schemes'
            { "label",               types.varchar },
            { "description",         types.text({ null = true }) },
            { "hmrc_mapping",        types.text({ null = true }) },       -- JSON, e.g. {"sa100_box":"TR4.3"}
            { "supports_relief_flag", types.boolean({ default = false }) }, -- show "Basic rate tax relief claimed by provider?"
            { "supports_one_off_flag", types.boolean({ default = false }) }, -- show "Is this a one-off payment?"
            { "display_order",       types.integer({ default = 0 }) },
            { "is_active",           types.boolean({ default = true }) },
            { "created_at",          types.time({ default = db.raw("NOW()") }) },
            { "updated_at",          types.time({ default = db.raw("NOW()") }) },
            "PRIMARY KEY (id)"
        })
        schema.create_index("pension_payment_categories", "is_active")
        print("[Pension Payments] Created pension_payment_categories table")
    end,

    -- =========================================================================
    -- 2. Seed the three TR4 sections.
    --    Idempotent: keyed on category_key; re-running updates labels and box
    --    mappings but never duplicates or resurrects disabled rows.
    -- =========================================================================
    [2] = function()
        local rows = {
            {
                key = "pp_registered_schemes",
                label = "Payments into registered schemes and retirement annuity contracts",
                desc = "Personal payments into registered pension schemes and retirement annuity contracts. "
                    .. "Tick 'relief claimed by provider' where the scheme adds basic-rate tax relief for you (relief at source).",
                mapping = '{"sa100_box":"TR4.1","sa100_box_no_relief":"TR4.2","sa100_box_one_off":"TR4.1.1"}',
                relief_flag = true,
                one_off_flag = true,
                order = 1,
            },
            {
                key = "pp_employer_schemes",
                label = "Payments to employer schemes not deducted from gross pay",
                desc = "Contributions to your employer's pension scheme that were taken from pay AFTER tax, "
                    .. "so no tax relief has been given yet.",
                mapping = '{"sa100_box":"TR4.3"}',
                relief_flag = false,
                one_off_flag = false,
                order = 2,
            },
            {
                key = "pp_overseas_schemes",
                label = "Payments to eligible overseas schemes not deducted from gross pay",
                desc = "Payments to a qualifying overseas pension scheme, paid out of taxed income and "
                    .. "eligible for UK tax relief.",
                mapping = '{"sa100_box":"TR4.4"}',
                relief_flag = false,
                one_off_flag = false,
                order = 3,
            },
        }
        for _, r in ipairs(rows) do
            local exists = db.select("id FROM pension_payment_categories WHERE category_key = ?", r.key)
            if exists and #exists > 0 then
                db.query([[
                    UPDATE pension_payment_categories
                       SET label = ?, description = ?, hmrc_mapping = ?,
                           supports_relief_flag = ?, supports_one_off_flag = ?,
                           display_order = ?, updated_at = NOW()
                     WHERE category_key = ?
                ]], r.label, r.desc, r.mapping, r.relief_flag, r.one_off_flag, r.order, r.key)
            else
                db.query([[
                    INSERT INTO pension_payment_categories
                        (uuid, category_key, label, description, hmrc_mapping,
                         supports_relief_flag, supports_one_off_flag,
                         display_order, is_active, created_at, updated_at)
                    VALUES (?, ?, ?, ?, ?, ?, ?, ?, true, NOW(), NOW())
                ]], MigrationUtils.generateUUID(), r.key, r.label, r.desc, r.mapping,
                    r.relief_flag, r.one_off_flag, r.order)
            end
        end
        print("[Pension Payments] Seeded pension_payment_categories (SA100 TR4)")
    end,

    -- =========================================================================
    -- 3. pension_payment_items
    --    category_key references pension_payment_categories.category_key —
    --    varchar, no FK, same softness rationale as property_line_items:
    --    retiring a section must never cascade-destroy historical rows.
    -- =========================================================================
    [3] = function()
        schema.create_table("pension_payment_items", {
            { "id",               types.serial },
            { "uuid",             types.varchar({ unique = true }) },
            { "user_id",          types.integer },
            { "namespace_id",     types.integer({ null = true }) },
            { "tax_year",         types.varchar },                  -- YYYY-YY e.g. "2026-27"
            { "category_key",     types.varchar },                  -- pension_payment_categories key
            { "description",      types.text({ null = true }) },    -- "Provider and payment description"
            { "amount",           "numeric(15,2) NOT NULL" },
            { "relief_at_source", types.boolean({ default = false }) }, -- basic-rate relief claimed by provider
            { "one_off",          types.boolean({ default = false }) },
            { "is_archived",      types.boolean({ default = false }) },
            { "archived_at",      types.time({ null = true }) },
            { "archived_by",      types.integer({ null = true }) },
            { "created_at",       types.time({ default = db.raw("NOW()") }) },
            { "updated_at",       types.time({ default = db.raw("NOW()") }) },
            "PRIMARY KEY (id)"
        })
        schema.create_index("pension_payment_items", "user_id")
        schema.create_index("pension_payment_items", "tax_year")
        schema.create_index("pension_payment_items", "user_id", "tax_year", "is_archived")
        print("[Pension Payments] Created pension_payment_items table")
    end,

    -- =========================================================================
    -- 4. income_types catalogue row — makes "Pension payments (tax relief)"
    --    selectable in the profile questionnaire and on /my-income. It's a
    --    RELIEF rather than income, but the selected_income_types question is
    --    how users opt sections onto their return, so it lives in the same
    --    catalogue (display name spells out the distinction from the existing
    --    'pension' income type).
    -- =========================================================================
    [4] = function()
        local docs = cjson.encode({
            { key = "pension_contribution_statements", label = "Pension contribution statements or certificates", required = false },
        })
        db.query([[
            INSERT INTO income_types
                (uuid, income_type_key, display_name, description,
                 required_documents, allows_manual_entry,
                 keyword_rules, category_affinity, rules_markdown,
                 hmrc_mapping, display_order, is_active, namespace_id,
                 created_at, updated_at)
            VALUES (?, 'pension_payments', 'Pension payments (tax relief)',
                    'Payments you made INTO pension schemes that qualify for tax relief — not pension income.',
                    ?::jsonb, true,
                    '[]'::jsonb, '{}'::jsonb, NULL,
                    '{}'::jsonb, 65, true, NULL, NOW(), NOW())
            ON CONFLICT (income_type_key) DO NOTHING
        ]], MigrationUtils.generateUUID(), docs)
        print("[Pension Payments] Seeded pension_payments income type")
    end,
}
