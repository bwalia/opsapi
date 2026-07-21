--[[
  Overseas Property System — "Land and property abroad" (SA106 foreign
  property pages), third instance of the hub + per-entity drill-down
  architecture (rental → property, self-employment → business):

  1. Overseas holdings are user_profile_entities rows with
     entity_type='overseas_property' — one per country/holding, matching
     the reference form's unit (Country + number of properties + address).
  2. Per-holding QUESTIONS (country, number of properties, address,
     accounting basis, property-income-allowance claim) are a Profile
     Builder category with context='overseas_property', answered with
     entity_uuid scope — admin-configurable, never hardcoded.
  3. Line items REUSE property_line_items/property_line_categories: the
     catalogue gains a `schedule` column ('uk_property' | 'overseas_property')
     so each surface only sees its own categories. Overseas expenses are
     FREE-FORM rows (description + amount + private use), which is what
     the dormant disallowable_amount column was kept for.
  4. A new income_types row makes "Overseas property" selectable — the
     profile's selected_income_types question sources options straight
     from that catalogue, so no option seeding is needed.

  Only executed when PROJECT_CODE includes 'tax_copilot'.
]]

local schema = require("lapis.db.schema")
local types = schema.types
local db = require("lapis.db")
local cjson = require("cjson")
local MigrationUtils = require "helper.migration-utils"

return {
    -- =========================================================================
    -- 1. property_line_categories.schedule — which surface a category
    --    belongs to. Existing rows are UK ones; default keeps them that way.
    -- =========================================================================
    [1] = function()
        db.query("ALTER TABLE property_line_categories ADD COLUMN IF NOT EXISTS schedule varchar NOT NULL DEFAULT 'uk_property'")
        db.query("CREATE INDEX IF NOT EXISTS idx_plc_schedule ON property_line_categories (schedule)")
        print("[Overseas Property] Added schedule column to property_line_categories")
    end,

    -- =========================================================================
    -- 2. Seed the overseas (SA106-shaped) categories.
    --    Idempotent: keyed on (kind, category_key), same as the UK seed.
    --    Kinds beyond income/expense ('finance_cost', 'adjustment') exist so
    --    restricted finance costs are NOT summed into expenses — the
    --    reference form explicitly excludes them from the expense total.
    -- =========================================================================
    [2] = function()
        local rows = {
            { kind = "income", key = "op_rents", label = "Total rents and other receipts", box = "14", order = 1 },
            { kind = "income", key = "op_lease_premiums", label = "Premiums paid for the grant of a lease", box = "14", order = 2 },
            { kind = "expense", key = "op_expense", label = "Property expense", box = "24", order = 1,
              desc = "Excluding finance costs for residential properties. Use the private-use column for any part that isn't wholly for the letting." },
            { kind = "finance_cost", key = "op_finance_costs", label = "Interest and other finance costs", box = "24A", order = 1,
              desc = "Residential finance costs are restricted to basic-rate relief — they don't reduce profits directly" },
            { kind = "adjustment", key = "op_unused_rfc_bf", label = "Unused residential finance costs brought forward", box = "24B", order = 1 },
        }
        for _, r in ipairs(rows) do
            local mapping = '{"sa106_box":"' .. r.box .. '"}'
            local exists = db.select("id FROM property_line_categories WHERE kind = ? AND category_key = ?", r.kind, r.key)
            if exists and #exists > 0 then
                db.query([[
                    UPDATE property_line_categories
                       SET label = ?, description = ?, hmrc_mapping = ?, display_order = ?,
                           schedule = 'overseas_property', updated_at = NOW()
                     WHERE kind = ? AND category_key = ?
                ]], r.label, r.desc or db.NULL, mapping, r.order, r.kind, r.key)
            else
                db.query([[
                    INSERT INTO property_line_categories
                        (uuid, kind, category_key, label, description, hmrc_mapping, display_order, schedule, is_active, created_at, updated_at)
                    VALUES (?, ?, ?, ?, ?, ?, ?, 'overseas_property', true, NOW(), NOW())
                ]], MigrationUtils.generateUUID(), r.kind, r.key, r.label, r.desc or db.NULL, mapping, r.order)
            end
        end
        print("[Overseas Property] Seeded overseas_property line categories (SA106)")
    end,

    -- =========================================================================
    -- 3. income_types catalogue row — makes "Overseas property" selectable
    --    in the profile questionnaire (selected_income_types sources its
    --    options from this catalogue) and on /my-income.
    -- =========================================================================
    [3] = function()
        local docs = cjson.encode({
            { key = "rental_statements", label = "Rental / letting statements", required = false },
            { key = "overseas_tax_docs", label = "Overseas tax paid — statements or certificates", required = false },
        })
        db.query([[
            INSERT INTO income_types
                (uuid, income_type_key, display_name, description,
                 required_documents, allows_manual_entry,
                 keyword_rules, category_affinity, rules_markdown,
                 hmrc_mapping, display_order, is_active, namespace_id,
                 created_at, updated_at)
            VALUES (?, 'overseas_property', 'Overseas property',
                    'Rent from land and property outside the UK.',
                    ?::jsonb, true,
                    '[]'::jsonb, '{}'::jsonb, NULL,
                    '{}'::jsonb, 45, true, NULL, NOW(), NOW())
            ON CONFLICT (income_type_key) DO NOTHING
        ]], MigrationUtils.generateUUID(), docs)
        print("[Overseas Property] Seeded overseas_property income type")
    end,

    -- =========================================================================
    -- 4. Seed the per-holding contexted question section
    --    (context='overseas_property', answered with entity_uuid scope).
    --    Same idempotent helpers as property-income-system [7].
    -- =========================================================================
    [4] = function()
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
            -- parent_option_id must be an EXPLICIT NULL — types.integer({null=true})
            -- renders `integer DEFAULT 0`, which violates fk_pqo_parent (#476).
            db.query([[
                INSERT INTO profile_question_options
                    (uuid, question_id, label, value, display_order, is_active, parent_option_id, created_at, updated_at)
                VALUES (?, ?, ?, ?, ?, true, NULL, NOW(), NOW())
            ]], MigrationUtils.generateUUID(), q[1].id, label, value, display_order)
        end

        -- ── Overseas holding details (asked once PER holding) ───────────────
        local od_id = ensure_category("overseas-property-details", "About this overseas property",
            "Details about this land or property abroad", "globe", 1, "overseas_property")
        if od_id then
            -- question_type values MUST be in profile_questions.chk_question_type
            -- ('short_text', not 'text' — see #481).
            ensure_question(od_id, { question_key = "op_country", label = "Which country is the property in?",
                question_type = "short_text", is_required = true, display_order = 1,
                placeholder = "e.g. Spain" })
            ensure_question(od_id, { question_key = "op_num_properties", label = "Number of properties in this country",
                question_type = "number", is_required = false, display_order = 2, placeholder = "1" })
            ensure_question(od_id, { question_key = "op_address", label = "Property address",
                question_type = "address", is_required = false, display_order = 3 })
            ensure_question(od_id, { question_key = "op_accounting_basis", label = "How do you record income and expenses?",
                question_type = "single_select", is_required = false, display_order = 4,
                help_text = "Cash basis counts money when it actually moves; accruals counts it when it's due." })
            ensure_question(od_id, { question_key = "op_claim_property_allowance", label = "Claim the £1,000 property income allowance?",
                question_type = "boolean", is_required = false, display_order = 5,
                help_text = "If you claim the allowance your expenses are ignored — and it's ONE allowance across all your property income (UK and overseas), not one per property." })
        end
        ensure_option("op_accounting_basis", "cash", "Cash basis", 1)
        ensure_option("op_accounting_basis", "accruals", "Accruals (traditional) basis", 2)
        print("[Overseas Property] Seeded overseas-property-details section: 5 questions")
    end,
}
