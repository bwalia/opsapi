--[[
  Form Sections System — the generic "sections with sub-form rows" engine.

  Ends the copy-a-new-Lua-stack-per-screen cycle for the whole family of
  screens shaped like "Relief: Pension payments": a page (anchored to an
  income_types row) made of admin-defined SECTIONS, each a repeating-row
  grid of description + amount + configurable checkboxes, with per-section
  totals. Adding the next such screen (charitable giving, other reliefs…)
  is now: admin creates an income_types row + tax_form_sections rows in
  the admin UI. No migration, no routes, no deploy.

  1. tax_form_sections : the section catalogue. Keyed by
     (income_type_key, section_key); config_json describes the sub-form
     (field labels + the checkbox definitions that used to be hardcoded
     supports_* boolean columns on pension_payment_categories).
  2. tax_form_items    : the user's rows. description + amount are real
     columns (amount must be SQL-summable for totals); checkbox values
     live in extra_json, validated against the section's config.
  3. Ports the pension-payments data (sections + any rows) onto the
     engine — the pension-specific routes/queries are retired in the same
     release; the old tables stay behind as an inert safety net.

  What this engine deliberately does NOT cover: per-entity drill-down
  hubs (rental/self-employment/overseas — user_profile_entities) and
  fixed-box grids (SA103 business_line_values). Different paradigms.

  Only executed when PROJECT_CODE includes 'tax_copilot'.
]]

local schema = require("lapis.db.schema")
local types = schema.types
local db = require("lapis.db")
local cjson = require("cjson")
local MigrationUtils = require "helper.migration-utils"

return {
    -- =========================================================================
    -- 1. tax_form_sections (admin catalogue — one row per sub-form section)
    -- =========================================================================
    [1] = function()
        schema.create_table("tax_form_sections", {
            { "id",              types.serial },
            { "uuid",            types.varchar({ unique = true }) },
            { "namespace_id",    types.integer({ null = true }) },
            { "income_type_key", types.varchar },                 -- income_types.income_type_key (page anchor)
            { "section_key",     types.varchar },                 -- stable key, e.g. 'pp_registered_schemes'
            { "label",           types.varchar },
            { "description",     types.text({ null = true }) },
            { "hmrc_mapping",    types.text({ null = true }) },   -- JSON, e.g. {"sa100_box":"TR4.3"}
            -- JSON sub-form config:
            --   { description_label?, description_placeholder?, amount_label?,
            --     amount_help?, checkboxes: [{key, label, help?}] }
            { "config_json",     types.text({ null = true }) },
            { "display_order",   types.integer({ default = 0 }) },
            { "is_active",       types.boolean({ default = true }) },
            { "created_at",      types.time({ default = db.raw("NOW()") }) },
            { "updated_at",      types.time({ default = db.raw("NOW()") }) },
            "PRIMARY KEY (id)"
        })
        schema.create_index("tax_form_sections", "income_type_key")
        schema.create_index("tax_form_sections", "is_active")
        db.query("CREATE UNIQUE INDEX IF NOT EXISTS idx_tfs_type_section ON tax_form_sections (income_type_key, section_key)")
        print("[Form Sections] Created tax_form_sections table")
    end,

    -- =========================================================================
    -- 2. tax_form_items (user rows, per section + tax year; soft archive)
    -- =========================================================================
    [2] = function()
        schema.create_table("tax_form_items", {
            { "id",              types.serial },
            { "uuid",            types.varchar({ unique = true }) },
            { "user_id",         types.integer },
            { "namespace_id",    types.integer({ null = true }) },
            { "income_type_key", types.varchar },
            { "section_key",     types.varchar },
            { "tax_year",        types.varchar },                 -- YYYY-YY e.g. "2026-27"
            { "description",     types.text({ null = true }) },
            { "amount",          "numeric(15,2) NOT NULL" },
            { "extra_json",      types.text({ null = true }) },   -- JSON {checkbox_key: true, ...}
            { "is_archived",     types.boolean({ default = false }) },
            { "archived_at",     types.time({ null = true }) },
            { "archived_by",     types.integer({ null = true }) },
            { "created_at",      types.time({ default = db.raw("NOW()") }) },
            { "updated_at",      types.time({ default = db.raw("NOW()") }) },
            "PRIMARY KEY (id)"
        })
        schema.create_index("tax_form_items", "user_id")
        schema.create_index("tax_form_items", "user_id", "tax_year", "is_archived")
        schema.create_index("tax_form_items", "user_id", "income_type_key", "tax_year", "is_archived")
        print("[Form Sections] Created tax_form_items table")
    end,

    -- =========================================================================
    -- 3. Port pension payments onto the engine. Idempotent both ways:
    --    sections keyed on (income_type_key, section_key), items carry their
    --    source row's uuid (unique) so a re-run can never duplicate.
    --    The old pension_payment_* tables are left in place, inert.
    -- =========================================================================
    [3] = function()
        -- The FE strings that used to be hardcoded in the pension page's
        -- modal live in config_json now.
        local base_config = {
            description_label = "Provider and payment description",
            description_placeholder = "e.g. Aviva personal pension — monthly contributions",
            amount_label = "Payment made (£)",
            amount_help = "Enter what you actually paid — don’t add basic-rate tax relief on top.",
        }
        local checkbox_defs = {
            relief_at_source = {
                key = "relief_at_source",
                label = "Basic rate tax relief claimed by provider",
                help = "Tick if the scheme adds basic-rate relief to your payments for you (relief at source) — most personal pensions do.",
            },
            one_off = {
                key = "one_off",
                label = "This is a one-off payment",
                help = "Single payments HMRC shouldn’t expect again next year — it helps keep your tax code accurate.",
            },
        }

        local cats = db.query([[
            SELECT category_key, label, description, hmrc_mapping,
                   supports_relief_flag, supports_one_off_flag,
                   display_order, is_active
            FROM pension_payment_categories
        ]]) or {}
        for _, c in ipairs(cats) do
            local config = {
                description_label = base_config.description_label,
                description_placeholder = base_config.description_placeholder,
                amount_label = base_config.amount_label,
                amount_help = base_config.amount_help,
                checkboxes = {},
            }
            if c.supports_relief_flag then
                config.checkboxes[#config.checkboxes + 1] = checkbox_defs.relief_at_source
            end
            if c.supports_one_off_flag then
                config.checkboxes[#config.checkboxes + 1] = checkbox_defs.one_off
            end
            -- cjson encodes {} ambiguously; force an array for checkboxes.
            if #config.checkboxes == 0 then config.checkboxes = cjson.empty_array end

            local exists = db.select(
                "id FROM tax_form_sections WHERE income_type_key = ? AND section_key = ?",
                "pension_payments", c.category_key)
            if not exists or #exists == 0 then
                db.query([[
                    INSERT INTO tax_form_sections
                        (uuid, income_type_key, section_key, label, description,
                         hmrc_mapping, config_json, display_order, is_active,
                         created_at, updated_at)
                    VALUES (?, 'pension_payments', ?, ?, ?, ?, ?, ?, ?, NOW(), NOW())
                ]], MigrationUtils.generateUUID(), c.category_key, c.label,
                    c.description or db.NULL, c.hmrc_mapping or db.NULL,
                    cjson.encode(config), c.display_order or 0,
                    c.is_active ~= false)
            end
        end

        local items = db.query("SELECT * FROM pension_payment_items") or {}
        for _, it in ipairs(items) do
            local extra = {}
            if it.relief_at_source then extra.relief_at_source = true end
            if it.one_off then extra.one_off = true end
            local extra_json = next(extra) and cjson.encode(extra) or db.NULL
            db.query([[
                INSERT INTO tax_form_items
                    (uuid, user_id, namespace_id, income_type_key, section_key,
                     tax_year, description, amount, extra_json,
                     is_archived, archived_at, archived_by, created_at, updated_at)
                VALUES (?, ?, ?, 'pension_payments', ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                ON CONFLICT (uuid) DO NOTHING
            ]], it.uuid, it.user_id, it.namespace_id or db.NULL, it.category_key,
                it.tax_year, it.description or db.NULL, it.amount, extra_json,
                it.is_archived == true, it.archived_at or db.NULL,
                it.archived_by or db.NULL, it.created_at, it.updated_at)
        end
        print("[Form Sections] Ported pension payments: " .. #cats .. " sections, " .. #items .. " items")
    end,
}
