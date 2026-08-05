--[[
  Self-Employment System — Sole-trader income redesign (hub + per-business
  drill-down), following the Property Income System pattern one-for-one:

  1. Businesses are user_profile_entities rows with entity_type='business'
     (the table was built generic for exactly this reuse — no schema change).
  2. Per-business QUESTIONS (description, address, dates, accounting basis)
     are Profile Builder categories with context='business', answered with
     entity_uuid scope — admin-configurable, never hardcoded in the frontend.
  3. business_line_categories : admin catalogue of the SA103 "boxes" the
     trade form renders — income / allowance / expense / capital_allowance /
     adjustment / balance_sheet — with hmrc_mapping for box routing.
     Unlike rental line items (free rows, add-as-many-as-you-like), the
     self-employment form is FIXED-BOX: one value per category per business
     per tax year, edited in place.
  4. business_line_values     : those values (amount + optional disallowable
     split for expenses). Upsert semantics — clearing a box deletes the row.
  5. business_ca_pools/rows   : admin catalogues for the Capital Allowances
     grid (columns = asset pools, rows = computation lines) replicated from
     the reference layout.
  6. business_ca_values       : one cell of that grid per (business, tax
     year, pool, row).

  Only executed when PROJECT_CODE includes 'tax_copilot'.
]]

local schema = require("lapis.db.schema")
local types = schema.types
local db = require("lapis.db")
local MigrationUtils = require "helper.migration-utils"

return {
    -- =========================================================================
    -- 1. business_line_categories (admin catalogue for the fixed-box form)
    -- =========================================================================
    [1] = function()
        schema.create_table("business_line_categories", {
            { "id",                    types.serial },
            { "uuid",                  types.varchar({ unique = true }) },
            { "namespace_id",          types.integer({ null = true }) },
            { "kind",                  types.varchar },               -- income|allowance|expense|capital_allowance|adjustment|balance_sheet
            { "category_key",          types.varchar },               -- stable key, e.g. 'turnover'
            { "label",                 types.varchar },
            { "description",           types.text({ null = true }) },
            { "hmrc_mapping",          types.text({ null = true }) }, -- JSON, e.g. {"sa103f_box":"15"}
            { "supports_disallowable", types.boolean({ default = false }) },
            { "display_order",         types.integer({ default = 0 }) },
            { "is_active",             types.boolean({ default = true }) },
            { "created_at",            types.time({ default = db.raw("NOW()") }) },
            { "updated_at",            types.time({ default = db.raw("NOW()") }) },
            "PRIMARY KEY (id)"
        })
        schema.create_index("business_line_categories", "kind")
        schema.create_index("business_line_categories", "is_active")
        -- category_key is globally unique (not per-kind): value rows store
        -- the key alone and the upsert conflict target must be unambiguous.
        db.query("CREATE UNIQUE INDEX IF NOT EXISTS idx_blc_key ON business_line_categories (category_key)")
        print("[Self Employment] Created business_line_categories table")
    end,

    -- =========================================================================
    -- 2. Seed the SA103F-shaped catalogue.
    --    Idempotent: keyed on category_key; re-running updates labels and
    --    mappings but never duplicates or resurrects disabled rows.
    -- =========================================================================
    [2] = function()
        local rows = {
            -- Income (SA103F boxes 15/16)
            { kind = "income", key = "turnover", label = "Business turnover", box = "15", order = 1,
              desc = "Your takings, fees and sales before any expenses" },
            { kind = "income", key = "other_income", label = "Any other business income", box = "16", order = 2,
              desc = "e.g. grants or rental income from business premises — not the trading allowance" },
            -- Trading income allowance (box 16.1)
            { kind = "allowance", key = "trading_income_allowance", label = "Trading income allowance claimed (up to £1,000)", box = "16.1", order = 1,
              desc = "If you claim the allowance you can't also claim expenses. Only worth it when expenses are under £1,000 — and it's one allowance across ALL your trades." },
            -- Expenses (SA103F boxes 17–30, disallowable 32–45)
            { kind = "expense", key = "cost_of_goods",         label = "Cost of goods bought for resale or goods used",     box = "17", dbox = "32", order = 1 },
            { kind = "expense", key = "cis_subcontractors",    label = "Construction industry — payments to subcontractors", box = "18", dbox = "33", order = 2 },
            { kind = "expense", key = "wages_staff",           label = "Wages, salaries and other staff costs",             box = "19", dbox = "34", order = 3,
              desc = "Don't include money you took out for yourself — that's drawings, not an expense" },
            { kind = "expense", key = "car_van_travel",        label = "Car, van and travel expenses",                      box = "20", dbox = "35", order = 4 },
            { kind = "expense", key = "rent_rates_power",      label = "Rent, rates, power and insurance costs",            box = "21", dbox = "36", order = 5 },
            { kind = "expense", key = "repairs_maintenance",   label = "Repairs and maintenance of property and equipment", box = "22", dbox = "37", order = 6 },
            { kind = "expense", key = "phone_office",          label = "Phone, fax, stationery and other office costs",     box = "23", dbox = "38", order = 7 },
            { kind = "expense", key = "advertising",           label = "Advertising costs",                                 box = "24", dbox = "39", order = 8 },
            { kind = "expense", key = "business_entertainment", label = "Business entertainment costs",                     box = "24", dbox = "39", order = 9,
              desc = "Client entertainment is normally disallowable for tax — record it in the disallowable column too" },
            { kind = "expense", key = "interest_loans",        label = "Interest on bank and other loans",                  box = "25", dbox = "40", order = 10 },
            { kind = "expense", key = "bank_charges",          label = "Bank, credit card and other financial charges",     box = "26", dbox = "41", order = 11 },
            { kind = "expense", key = "irrecoverable_debts",   label = "Irrecoverable debts written off",                   box = "27", dbox = "42", order = 12 },
            { kind = "expense", key = "professional_fees",     label = "Accountancy, legal and other professional fees",    box = "28", dbox = "43", order = 13 },
            { kind = "expense", key = "depreciation",          label = "Depreciation and loss/profit on sale of assets",    box = "29", dbox = "44", order = 14,
              desc = "Depreciation is always disallowable for tax — claim capital allowances instead" },
            { kind = "expense", key = "other_expenses",        label = "Other business expenses",                           box = "30", dbox = "45", order = 15 },
            -- Capital allowances & non-taxable items (SA103F boxes 49–59)
            { kind = "capital_allowance", key = "aia",                        label = "Annual Investment Allowance",                                        box = "49", order = 1 },
            { kind = "capital_allowance", key = "small_pool_balance",         label = "Small pool balance written off",                                     box = "50", order = 2 },
            { kind = "capital_allowance", key = "ca_equipment_main",          label = "Capital allowance on equipment — main rate",                         box = "50", order = 3 },
            { kind = "capital_allowance", key = "ca_equipment_special",       label = "Capital allowance on equipment — special rate",                      box = "51", order = 4 },
            { kind = "capital_allowance", key = "ca_single_asset_main",       label = "Capital allowances on single asset pools — main rate",               box = "50", order = 5 },
            { kind = "capital_allowance", key = "ca_single_asset_special",    label = "Capital allowances on single asset pools — special rate",            box = "51", order = 6 },
            { kind = "capital_allowance", key = "zero_emission_goods_vehicle", label = "Zero-emission goods vehicle allowance",                             box = "52", order = 7 },
            { kind = "capital_allowance", key = "zero_emission_car",          label = "Zero-emission car allowance",                                        box = "52", order = 8 },
            { kind = "capital_allowance", key = "sba",                        label = "Structures and Buildings Allowance",                                 box = "53", order = 9 },
            { kind = "capital_allowance", key = "freeport_sba",               label = "Freeport and Investment Zones Structures and Buildings Allowance",   box = "53", order = 10 },
            { kind = "capital_allowance", key = "electric_charge_point",      label = "Electric charge-point allowance",                                    box = "54", order = 11 },
            { kind = "capital_allowance", key = "enhanced_100",               label = "100% and other enhanced capital allowances",                         box = "54", order = 12 },
            -- Transitional profit / losses / other deductions (SA103F 68–75 area)
            { kind = "adjustment", key = "transitional_profit_bf",      label = "Transitional profit brought forward",       box = "73", order = 1,
              desc = "Basis-period reform: profit being spread from the 2023–24 transition year" },
            { kind = "adjustment", key = "accelerated_transition_profit", label = "Accelerated transition profit",           box = "73", order = 2,
              desc = "Extra transition profit you choose to tax this year on top of the automatic spread" },
            { kind = "adjustment", key = "transitional_profit_taxable", label = "Transitional profit taxable this year",     box = "73", order = 3 },
            { kind = "adjustment", key = "loss_brought_forward",        label = "Loss brought forward from earlier years",   box = "74", order = 4 },
            { kind = "adjustment", key = "non_arms_length_income",      label = "Any other business income (e.g. non-arm's-length reverse premiums)", box = "75", order = 5 },
            { kind = "adjustment", key = "fig_claim",                   label = "Amount claimed under the foreign income and gains (FIG) regime",     box = "75", order = 6 },
            { kind = "adjustment", key = "fig_loss_adjustment",         label = "Adjustment to losses from a FIG regime claim",                       box = "75", order = 7 },
            -- Balance sheet (SA103F boxes 83–99; optional section)
            { kind = "balance_sheet", key = "bs_equipment",            label = "Equipment, machinery and vehicles",     box = "83", order = 1 },
            { kind = "balance_sheet", key = "bs_other_fixed_assets",   label = "Other fixed assets",                    box = "84", order = 2 },
            { kind = "balance_sheet", key = "bs_stock",                label = "Stock and work in progress",            box = "85", order = 3 },
            { kind = "balance_sheet", key = "bs_trade_debtors",        label = "Trade debtors",                         box = "86", order = 4 },
            { kind = "balance_sheet", key = "bs_bank",                 label = "Bank and building society balances",    box = "87", order = 5 },
            { kind = "balance_sheet", key = "bs_cash",                 label = "Cash in hand",                          box = "88", order = 6 },
            { kind = "balance_sheet", key = "bs_other_current_assets", label = "Other current assets and prepayments",  box = "89", order = 7 },
            { kind = "balance_sheet", key = "bs_trade_creditors",      label = "Trade creditors",                       box = "91", order = 8 },
            { kind = "balance_sheet", key = "bs_loans_overdrafts",     label = "Loans and overdrafts",                  box = "92", order = 9 },
            { kind = "balance_sheet", key = "bs_other_liabilities",    label = "Other liabilities and accruals",        box = "93", order = 10 },
            { kind = "balance_sheet", key = "bs_balance_start",        label = "Balance at start of period",            box = "94", order = 11 },
            { kind = "balance_sheet", key = "bs_capital_introduced",   label = "Capital introduced",                    box = "96", order = 12 },
            { kind = "balance_sheet", key = "bs_drawings",             label = "Drawings",                              box = "97", order = 13 },
        }
        for _, r in ipairs(rows) do
            local mapping = '{"sa103f_box":"' .. r.box .. '"'
                .. (r.dbox and (',"disallowable_box":"' .. r.dbox .. '"') or "")
                .. '}'
            local supports_disallowable = r.dbox and true or false
            local exists = db.select("id FROM business_line_categories WHERE category_key = ?", r.key)
            if exists and #exists > 0 then
                db.query([[
                    UPDATE business_line_categories
                       SET kind = ?, label = ?, description = ?, hmrc_mapping = ?,
                           supports_disallowable = ?, display_order = ?, updated_at = NOW()
                     WHERE category_key = ?
                ]], r.kind, r.label, r.desc or db.NULL, mapping, supports_disallowable, r.order, r.key)
            else
                db.query([[
                    INSERT INTO business_line_categories
                        (uuid, kind, category_key, label, description, hmrc_mapping, supports_disallowable, display_order, is_active, created_at, updated_at)
                    VALUES (?, ?, ?, ?, ?, ?, ?, ?, true, NOW(), NOW())
                ]], MigrationUtils.generateUUID(), r.kind, r.key, r.label, r.desc or db.NULL, mapping, supports_disallowable, r.order)
            end
        end
        print("[Self Employment] Seeded business_line_categories (SA103F boxes)")
    end,

    -- =========================================================================
    -- 3. business_line_values — ONE value per (business, tax year, category).
    --    business_uuid references user_profile_entities.uuid — varchar, no FK,
    --    same softness rationale as property_line_items.
    -- =========================================================================
    [3] = function()
        schema.create_table("business_line_values", {
            { "id",                  types.serial },
            { "uuid",                types.varchar({ unique = true }) },
            { "user_id",             types.integer },
            { "namespace_id",        types.integer({ null = true }) },
            { "business_uuid",       types.varchar },
            { "tax_year",            types.varchar },               -- YYYY-YY e.g. "2026-27"
            { "kind",                types.varchar },               -- denormalised from the catalogue for grouped sums
            { "category_key",        types.varchar },
            { "amount",              "numeric(15,2)" },             -- nullable: a disallowable-only entry keeps amount NULL
            { "disallowable_amount", "numeric(15,2)" },
            { "created_at",          types.time({ default = db.raw("NOW()") }) },
            { "updated_at",          types.time({ default = db.raw("NOW()") }) },
            "PRIMARY KEY (id)"
        })
        schema.create_index("business_line_values", "user_id")
        schema.create_index("business_line_values", "business_uuid")
        schema.create_index("business_line_values", "user_id", "tax_year")
        db.query([[
            CREATE UNIQUE INDEX IF NOT EXISTS idx_blv_cell
            ON business_line_values (user_id, business_uuid, tax_year, category_key)
        ]])
        print("[Self Employment] Created business_line_values table")
    end,

    -- =========================================================================
    -- 4. Capital Allowances grid catalogues (columns = pools, rows = lines)
    --    + seed replicating the reference layout. Admin-editable afterwards.
    -- =========================================================================
    [4] = function()
        schema.create_table("business_ca_pools", {
            { "id",            types.serial },
            { "uuid",          types.varchar({ unique = true }) },
            { "namespace_id",  types.integer({ null = true }) },
            { "pool_key",      types.varchar({ unique = true }) },
            { "label",         types.varchar },
            { "display_order", types.integer({ default = 0 }) },
            { "is_active",     types.boolean({ default = true }) },
            { "created_at",    types.time({ default = db.raw("NOW()") }) },
            { "updated_at",    types.time({ default = db.raw("NOW()") }) },
            "PRIMARY KEY (id)"
        })
        schema.create_table("business_ca_rows", {
            { "id",            types.serial },
            { "uuid",          types.varchar({ unique = true }) },
            { "namespace_id",  types.integer({ null = true }) },
            { "row_key",       types.varchar({ unique = true }) },
            { "label",         types.varchar },
            { "display_order", types.integer({ default = 0 }) },
            { "is_active",     types.boolean({ default = true }) },
            { "created_at",    types.time({ default = db.raw("NOW()") }) },
            { "updated_at",    types.time({ default = db.raw("NOW()") }) },
            "PRIMARY KEY (id)"
        })

        local pools = {
            { key = "pm_main",      label = "Plant & machinery — Main pool" },
            { key = "pm_special",   label = "Plant & machinery — Special rate pool" },
            { key = "short_life",   label = "Short life assets" },
            { key = "private_use",  label = "Assets with private use" },
            { key = "sba",          label = "Structures and Buildings Allowance" },
            { key = "rd",           label = "Research & Development" },
            { key = "know_how",     label = "Know-how" },
            { key = "patents",      label = "Patents" },
            { key = "freeport_sba", label = "Freeport and Investment Zones Structures and Buildings" },
        }
        for i, p in ipairs(pools) do
            local exists = db.select("id FROM business_ca_pools WHERE pool_key = ?", p.key)
            if exists and #exists > 0 then
                db.query("UPDATE business_ca_pools SET label = ?, display_order = ?, updated_at = NOW() WHERE pool_key = ?",
                    p.label, i, p.key)
            else
                db.query([[
                    INSERT INTO business_ca_pools (uuid, pool_key, label, display_order, is_active, created_at, updated_at)
                    VALUES (?, ?, ?, ?, true, NOW(), NOW())
                ]], MigrationUtils.generateUUID(), p.key, p.label, i)
            end
        end

        local ca_rows = {
            { key = "wdv_bf",                    label = "WDV B/Fwd" },
            { key = "additions_fya",             label = "Additions eligible for FYA" },
            { key = "fya_100",                   label = "FYA @ 100%" },
            { key = "additions_fya_40",          label = "Additions eligible for FYA (40%)" },
            { key = "fya_40_claimed",            label = "40% FYA claimed" },
            { key = "additions_aia",             label = "Additions eligible for AIA" },
            { key = "aia",                       label = "AIA (limit £1,000,000)" },
            { key = "other_additions",           label = "Other additions" },
            { key = "disposal_proceeds",         label = "Less: disposal proceeds" },
            { key = "balancing",                 label = "Balancing (allowance)/charge" },
            { key = "balancing_super_deduction", label = "Balancing charge on Super Deduction" },
            { key = "balancing_full_expensing",  label = "Balancing charge on Full Expensing" },
            { key = "residue",                   label = "Residue" },
            { key = "small_pools_wda",           label = "Small pools WDA" },
            { key = "wda",                       label = "WDA" },
            { key = "private_use_adj",           label = "Private use" },
            { key = "wda_not_claimed",           label = "WDA not claimed" },
            { key = "wdv_cf",                    label = "WDV C/Fwd" },
            { key = "allowances_claimed",        label = "Allowances claimed" },
        }
        for i, r in ipairs(ca_rows) do
            local exists = db.select("id FROM business_ca_rows WHERE row_key = ?", r.key)
            if exists and #exists > 0 then
                db.query("UPDATE business_ca_rows SET label = ?, display_order = ?, updated_at = NOW() WHERE row_key = ?",
                    r.label, i, r.key)
            else
                db.query([[
                    INSERT INTO business_ca_rows (uuid, row_key, label, display_order, is_active, created_at, updated_at)
                    VALUES (?, ?, ?, ?, true, NOW(), NOW())
                ]], MigrationUtils.generateUUID(), r.key, r.label, i)
            end
        end
        print("[Self Employment] Created + seeded business_ca_pools / business_ca_rows")
    end,

    -- =========================================================================
    -- 5. business_ca_values — one grid cell per (business, tax year, pool, row)
    -- =========================================================================
    [5] = function()
        schema.create_table("business_ca_values", {
            { "id",           types.serial },
            { "uuid",         types.varchar({ unique = true }) },
            { "user_id",      types.integer },
            { "namespace_id", types.integer({ null = true }) },
            { "business_uuid", types.varchar },
            { "tax_year",     types.varchar },
            { "pool_key",     types.varchar },
            { "row_key",      types.varchar },
            { "amount",       "numeric(15,2) NOT NULL" },
            { "created_at",   types.time({ default = db.raw("NOW()") }) },
            { "updated_at",   types.time({ default = db.raw("NOW()") }) },
            "PRIMARY KEY (id)"
        })
        schema.create_index("business_ca_values", "user_id")
        schema.create_index("business_ca_values", "business_uuid", "tax_year")
        db.query([[
            CREATE UNIQUE INDEX IF NOT EXISTS idx_bcv_cell
            ON business_ca_values (user_id, business_uuid, tax_year, pool_key, row_key)
        ]])
        print("[Self Employment] Created business_ca_values table")
    end,

    -- =========================================================================
    -- 6. Seed the per-business contexted question section (context='business',
    --    answered with entity_uuid scope — asked once PER business).
    --    Same idempotent helpers as property-income-system [7].
    -- =========================================================================
    [6] = function()
        local function ensure_category(slug, name, description, icon, display_order, context)
            local exists = db.select("id FROM profile_categories WHERE slug = ?", slug)
            if exists and #exists > 0 then
                db.query([[
                    UPDATE profile_categories
                       SET name = ?, description = ?, icon = ?, display_order = ?, context = ?,
                           is_active = true, is_archived = false, updated_at = NOW()
                     WHERE slug = ?
                ]], name, description, icon, display_order, context, slug)
                return exists[1].id
            end
            db.query([[
                INSERT INTO profile_categories
                    (uuid, namespace_id, name, slug, description, icon, display_order, context, is_active, is_archived, created_at, updated_at)
                VALUES (?, 0, ?, ?, ?, ?, ?, ?, true, false, NOW(), NOW())
            ]], MigrationUtils.generateUUID(), name, slug, description, icon, display_order, context)
            local row = db.select("id FROM profile_categories WHERE slug = ?", slug)
            return row and row[1] and row[1].id or nil
        end

        local function ensure_question(cat_id, q)
            local exists = db.select("id FROM profile_questions WHERE question_key = ?", q.question_key)
            if exists and #exists > 0 then
                db.query([[
                    UPDATE profile_questions
                       SET category_id = ?, label = ?, question_type = ?, is_required = ?,
                           display_order = ?, help_text = ?, placeholder = ?,
                           is_active = true, is_archived = false, updated_at = NOW()
                     WHERE question_key = ?
                ]], cat_id, q.label, q.question_type, q.is_required, q.display_order, q.help_text or "", q.placeholder or "", q.question_key)
                return exists[1].id
            end
            db.query([[
                INSERT INTO profile_questions
                    (uuid, category_id, question_key, label, question_type, is_required, display_order, help_text, placeholder, is_active, version, created_at, updated_at)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, true, 1, NOW(), NOW())
            ]], MigrationUtils.generateUUID(), cat_id, q.question_key, q.label, q.question_type, q.is_required, q.display_order, q.help_text or "", q.placeholder or "")
            local row = db.select("id FROM profile_questions WHERE question_key = ?", q.question_key)
            return row and row[1] and row[1].id or nil
        end

        local function ensure_option(question_key, value, label, display_order)
            local q = db.select("id FROM profile_questions WHERE question_key = ?", question_key)
            if not q or #q == 0 then return end
            local exists = db.select("id FROM profile_question_options WHERE question_id = ? AND value = ?", q[1].id, value)
            if exists and #exists > 0 then return end
            -- parent_option_id must be an EXPLICIT NULL: the column is
            -- types.integer({null = true}), which Lapis renders as
            -- `integer DEFAULT 0` — omitting it inserts 0 and violates the
            -- self-referencing fk_pqo_parent constraint (broke migrate on int
            -- for the property-income seed).
            db.query([[
                INSERT INTO profile_question_options
                    (uuid, question_id, label, value, display_order, is_active, parent_option_id, created_at, updated_at)
                VALUES (?, ?, ?, ?, ?, true, NULL, NOW(), NOW())
            ]], MigrationUtils.generateUUID(), q[1].id, label, value, display_order)
        end

        local function ensure_rule(target_key, source_key, rule_name, operator, expected_value)
            local tgt = db.select("id FROM profile_questions WHERE question_key = ?", target_key)
            local src = db.select("id FROM profile_questions WHERE question_key = ?", source_key)
            if not tgt or #tgt == 0 or not src or #src == 0 then return end
            local exists = db.select("id FROM profile_question_rules WHERE question_id = ? AND source_question_id = ?", tgt[1].id, src[1].id)
            if exists and #exists > 0 then return end
            db.query([[
                INSERT INTO profile_question_rules
                    (uuid, question_id, rule_name, rule_type, operator, source_question_id, expected_value, logic_group, is_active, created_at, updated_at)
                VALUES (?, ?, ?, 'visibility', ?, ?, ?, 'AND', true, NOW(), NOW())
            ]], MigrationUtils.generateUUID(), tgt[1].id, rule_name, operator, src[1].id, expected_value)
        end

        -- ── Business details (asked once PER business) ──────────────────────
        local bd_id = ensure_category("business-details", "Business details",
            "Details about this business", "briefcase", 1, "business")
        if bd_id then
            -- 'short_text', not 'text' — profile_questions.chk_question_type
            -- has a fixed whitelist and 'text' is not in it (broke migrate
            -- 736 on int with a check-constraint violation).
            ensure_question(bd_id, { question_key = "se_description", label = "What does the business do?",
                question_type = "short_text", is_required = false, display_order = 1,
                placeholder = "e.g. Plumbing and heating services" })
            ensure_question(bd_id, { question_key = "se_address", label = "Business address (unless you work from home)",
                question_type = "address", is_required = false, display_order = 2 })
            ensure_question(bd_id, { question_key = "se_details_changed", label = "Did the business name or address change in the last 12 months?",
                question_type = "boolean", is_required = false, display_order = 3 })
            ensure_question(bd_id, { question_key = "se_start_date", label = "When did the business start?",
                question_type = "date", is_required = false, display_order = 4,
                help_text = "Only needed if it started within this tax year" })
            ensure_question(bd_id, { question_key = "se_ceased", label = "Has the business stopped trading?",
                question_type = "boolean", is_required = false, display_order = 5 })
            ensure_question(bd_id, { question_key = "se_cessation_date", label = "When did it stop?",
                question_type = "date", is_required = false, display_order = 6 })
            ensure_question(bd_id, { question_key = "se_accounting_basis", label = "How do you record income and expenses?",
                question_type = "single_select", is_required = false, display_order = 7,
                help_text = "Cash basis counts money when it actually moves; traditional (accruals) counts it when it's due. Most sole traders use cash basis." })
            ensure_question(bd_id, { question_key = "se_period_start", label = "Start of accounting period",
                question_type = "date", is_required = false, display_order = 8,
                help_text = "Most sole traders use 6 April to 5 April — leave blank if unsure" })
            ensure_question(bd_id, { question_key = "se_period_end", label = "End of accounting period",
                question_type = "date", is_required = false, display_order = 9 })
        end
        ensure_option("se_accounting_basis", "cash", "Cash basis (recommended for most sole traders)", 1)
        ensure_option("se_accounting_basis", "accruals", "Traditional (accruals) accounting", 2)
        ensure_rule("se_cessation_date", "se_ceased", "Show when business has ceased", "equals", "true")
        print("[Self Employment] Seeded business-details section: 9 questions, 1 rule")
    end,
}
