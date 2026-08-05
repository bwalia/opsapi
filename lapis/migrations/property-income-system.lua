--[[
  Property Income System — Rental / Property income redesign.

  Adds the pieces that let the Rental income panel become a
  "hub + per-property drill-down" (option A of the UX redesign) while
  keeping every question admin-configurable through the existing
  Dynamic Profile Builder:

  1. user_profile_entities      : user-owned instances ("10 High Street…")
                                  that answers can be scoped to. Today
                                  entity_type is always 'property'; the
                                  table is deliberately generic so a later
                                  feature (e.g. multiple self-employments)
                                  can reuse it.
  2. user_profile_answers       : gains entity_uuid. NULL = the classic
                                  one-answer-per-user questionnaire;
                                  non-NULL = the answer belongs to that
                                  entity (asked once PER PROPERTY).
  3. profile_categories.context : NULL  = normal /profile questionnaire
                                  'rental_business' = asked once, on the
                                                      rental hub
                                  'property'        = asked per property
                                  Contexted categories are EXCLUDED from
                                  the default /schema + completion gate.
  4. property_line_categories   : admin-managed catalogue for the income
                                  and expense line-item dropdowns, with
                                  hmrc_mapping for SA105 box routing
                                  (same pattern as income_types).
  5. property_line_items        : the user's rental income/expense rows,
                                  one row per line item per property per
                                  tax year. Soft-delete like my_incomes.

  Only executed when PROJECT_CODE includes 'tax_copilot'.
]]

local schema = require("lapis.db.schema")
local types = schema.types
local db = require("lapis.db")
local MigrationUtils = require "helper.migration-utils"

return {
    -- =========================================================================
    -- 1. user_profile_entities
    -- =========================================================================
    [1] = function()
        schema.create_table("user_profile_entities", {
            { "id",            types.serial },
            { "uuid",          types.varchar({ unique = true }) },
            { "user_id",       types.integer },
            { "user_uuid",     types.varchar },
            { "namespace_id",  types.integer({ null = true }) },
            { "entity_type",   types.varchar },                    -- 'property' (generic for future reuse)
            { "label",         types.varchar },                    -- user-facing nickname, e.g. "10 High Street"
            { "metadata_json", types.text({ null = true }) },
            { "display_order", types.integer({ default = 0 }) },
            { "is_archived",   types.boolean({ default = false }) },
            { "archived_at",   types.time({ null = true }) },
            { "created_at",    types.time({ default = db.raw("NOW()") }) },
            { "updated_at",    types.time({ default = db.raw("NOW()") }) },
            "PRIMARY KEY (id)"
        })
        schema.create_index("user_profile_entities", "user_id")
        schema.create_index("user_profile_entities", "user_uuid")
        schema.create_index("user_profile_entities", "entity_type")
        schema.create_index("user_profile_entities", "user_id", "entity_type", "is_archived")
        print("[Property Income] Created user_profile_entities table")
    end,

    -- =========================================================================
    -- 2. entity_uuid on user_profile_answers
    --
    -- The single unique index (user_id, question_id) becomes TWO partial
    -- unique indexes so the same question can hold one answer per entity
    -- while classic questionnaire answers stay one-per-user:
    --   * entity_uuid IS NULL     → unique on (user_id, question_id)
    --   * entity_uuid IS NOT NULL → unique on (user_id, question_id, entity_uuid)
    -- The answers upsert in routes/profile-builder.lua targets whichever
    -- predicate applies (ON CONFLICT ... WHERE ...) — keep in lock-step.
    --
    -- ⚠ DEPLOY WINDOW: pre-migration code upserts with a bare
    -- `ON CONFLICT (user_id, question_id)`, which Postgres CANNOT satisfy
    -- from a partial index (42P10) — so between this migration running and
    -- the new code serving, answer saves on old pods fail (per-answer
    -- errors, nothing persisted; no crash). A plain unique index can't be
    -- kept alongside (it would forbid the per-entity rows this feature
    -- exists for), so the window is unavoidable in a single release:
    -- deploy at a quiet time and let the rollout complete promptly.
    -- =========================================================================
    [2] = function()
        db.query("ALTER TABLE user_profile_answers ADD COLUMN IF NOT EXISTS entity_uuid varchar NULL")
        db.query("DROP INDEX IF EXISTS idx_upa_user_question")
        db.query([[
            CREATE UNIQUE INDEX IF NOT EXISTS idx_upa_user_question
            ON user_profile_answers (user_id, question_id)
            WHERE entity_uuid IS NULL
        ]])
        db.query([[
            CREATE UNIQUE INDEX IF NOT EXISTS idx_upa_user_question_entity
            ON user_profile_answers (user_id, question_id, entity_uuid)
            WHERE entity_uuid IS NOT NULL
        ]])
        db.query("CREATE INDEX IF NOT EXISTS idx_upa_entity ON user_profile_answers (entity_uuid) WHERE entity_uuid IS NOT NULL")
        print("[Property Income] Added entity_uuid scope to user_profile_answers")
    end,

    -- =========================================================================
    -- 3. profile_categories.context
    -- =========================================================================
    [3] = function()
        db.query("ALTER TABLE profile_categories ADD COLUMN IF NOT EXISTS context varchar NULL")
        db.query("CREATE INDEX IF NOT EXISTS idx_pc_context ON profile_categories (context)")
        print("[Property Income] Added context column to profile_categories")
    end,

    -- =========================================================================
    -- 4. property_line_categories (admin catalogue for line-item dropdowns)
    -- =========================================================================
    [4] = function()
        schema.create_table("property_line_categories", {
            { "id",            types.serial },
            { "uuid",          types.varchar({ unique = true }) },
            { "namespace_id",  types.integer({ null = true }) },
            { "kind",          types.varchar },                    -- 'income' | 'expense'
            { "category_key",  types.varchar },                    -- stable key, e.g. 'repairs_maintenance'
            { "label",         types.varchar },
            { "description",   types.text({ null = true }) },
            { "hmrc_mapping",  types.text({ null = true }) },      -- JSON, e.g. {"sa105_box":"25"}
            { "display_order", types.integer({ default = 0 }) },
            { "is_active",     types.boolean({ default = true }) },
            { "created_at",    types.time({ default = db.raw("NOW()") }) },
            { "updated_at",    types.time({ default = db.raw("NOW()") }) },
            "PRIMARY KEY (id)"
        })
        schema.create_index("property_line_categories", "kind")
        schema.create_index("property_line_categories", "is_active")
        db.query("CREATE UNIQUE INDEX IF NOT EXISTS idx_plc_kind_key ON property_line_categories (kind, category_key)")
        print("[Property Income] Created property_line_categories table")
    end,

    -- =========================================================================
    -- 5. Seed SA105-shaped line categories.
    --    Idempotent: keyed on (kind, category_key); re-running updates labels
    --    and box mappings but never duplicates or resurrects disabled rows.
    -- =========================================================================
    [5] = function()
        local rows = {
            -- Income (SA105 boxes 20/22)
            { kind = "income",  key = "rents",              label = "Rental income",                                 box = "20", order = 1 },
            { kind = "income",  key = "other_income",       label = "Other property income",                         box = "20", order = 2,
              desc = "e.g. insurance payouts, service charges you keep" },
            { kind = "income",  key = "lease_premiums",     label = "Premiums for the grant of a lease",             box = "22", order = 3 },
            -- Expenses (SA105 boxes 24–29)
            { kind = "expense", key = "rates_insurance",    label = "Rent, rates, insurance and ground rents",       box = "24", order = 1 },
            { kind = "expense", key = "repairs_maintenance", label = "Property repairs and maintenance",             box = "25", order = 2 },
            { kind = "expense", key = "finance_costs",      label = "Loan interest and other financial costs",       box = "26", order = 3,
              desc = "Residential mortgage interest is restricted to basic-rate relief (box 44)" },
            { kind = "expense", key = "professional_fees",  label = "Legal, management and other professional fees", box = "27", order = 4 },
            { kind = "expense", key = "services_wages",     label = "Costs of services provided, including wages",   box = "28", order = 5 },
            { kind = "expense", key = "travel",             label = "Property-related travel costs",                 box = "29", order = 6 },
            { kind = "expense", key = "other_expenses",     label = "Other allowable property expenses",             box = "29", order = 7 },
        }
        for _, r in ipairs(rows) do
            local mapping = '{"sa105_box":"' .. r.box .. '"}'
            local exists = db.select("id FROM property_line_categories WHERE kind = ? AND category_key = ?", r.kind, r.key)
            if exists and #exists > 0 then
                db.query([[
                    UPDATE property_line_categories
                       SET label = ?, description = ?, hmrc_mapping = ?, display_order = ?, updated_at = NOW()
                     WHERE kind = ? AND category_key = ?
                ]], r.label, r.desc or db.NULL, mapping, r.order, r.kind, r.key)
            else
                db.query([[
                    INSERT INTO property_line_categories
                        (uuid, kind, category_key, label, description, hmrc_mapping, display_order, is_active, created_at, updated_at)
                    VALUES (?, ?, ?, ?, ?, ?, ?, true, NOW(), NOW())
                ]], MigrationUtils.generateUUID(), r.kind, r.key, r.label, r.desc or db.NULL, mapping, r.order)
            end
        end
        print("[Property Income] Seeded property_line_categories (SA105 boxes)")
    end,

    -- =========================================================================
    -- 6. property_line_items
    --    property_uuid references user_profile_entities.uuid — varchar, no FK,
    --    same softness rationale as my_incomes.income_type: archiving a
    --    property must never cascade-destroy its historical line items.
    -- =========================================================================
    [6] = function()
        schema.create_table("property_line_items", {
            { "id",                  types.serial },
            { "uuid",                types.varchar({ unique = true }) },
            { "user_id",             types.integer },
            { "namespace_id",        types.integer({ null = true }) },
            { "property_uuid",       types.varchar },
            { "tax_year",            types.varchar },               -- YYYY-YY e.g. "2026-27"
            { "kind",                types.varchar },               -- 'income' | 'expense'
            { "category_key",        types.varchar },               -- property_line_categories key
            { "description",         types.text({ null = true }) },
            { "amount",              "numeric(15,2) NOT NULL" },
            { "disallowable_amount", "numeric(15,2)" },             -- nullable; IRIS-style split kept for later UI
            { "is_archived",         types.boolean({ default = false }) },
            { "archived_at",         types.time({ null = true }) },
            { "archived_by",         types.integer({ null = true }) },
            { "created_at",          types.time({ default = db.raw("NOW()") }) },
            { "updated_at",          types.time({ default = db.raw("NOW()") }) },
            "PRIMARY KEY (id)"
        })
        schema.create_index("property_line_items", "user_id")
        schema.create_index("property_line_items", "property_uuid")
        schema.create_index("property_line_items", "tax_year")
        schema.create_index("property_line_items", "user_id", "property_uuid", "tax_year", "is_archived")
        schema.create_index("property_line_items", "user_id", "tax_year", "is_archived")
        print("[Property Income] Created property_line_items table")
    end,

    -- =========================================================================
    -- 7. Seed the two contexted question sections.
    --    Same ensure_* idempotent helpers as dynamic-profile-builder [38];
    --    admins can freely edit/extend these from the admin panel afterwards.
    -- =========================================================================
    [7] = function()
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
            -- self-referencing fk_pqo_parent constraint (broke migrate on int).
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

        -- ── Rental business (asked once, shown on the rental hub) ───────────
        local rb_id = ensure_category("rental-business", "Your rental business",
            "Details that apply to your property letting as a whole", "home", 1, "rental_business")
        if rb_id then
            ensure_question(rb_id, { question_key = "rb_accounting_basis", label = "How do you record income and expenses?",
                question_type = "single_select", is_required = true, display_order = 1,
                help_text = "Cash basis counts money when it actually moves; accruals counts it when it's due. Most landlords use cash basis." })
            ensure_question(rb_id, { question_key = "rb_claim_property_allowance", label = "Claim the £1,000 property income allowance?",
                question_type = "boolean", is_required = false, display_order = 2,
                help_text = "If you claim the allowance you can't also deduct expenses. Worth it only when your expenses are under £1,000." })
            ensure_question(rb_id, { question_key = "rb_jointly_let", label = "Do you let any property jointly with someone else?",
                question_type = "boolean", is_required = false, display_order = 3,
                help_text = "For jointly-let property, only your share of income and expenses goes on your return." })
            ensure_question(rb_id, { question_key = "rb_non_resident_landlord", label = "Did you live outside the UK while letting?",
                question_type = "boolean", is_required = false, display_order = 4 })
            ensure_question(rb_id, { question_key = "rb_first_letting_date", label = "When did you first start letting property?",
                question_type = "date", is_required = false, display_order = 5 })
        end
        ensure_option("rb_accounting_basis", "cash", "Cash basis (recommended for most landlords)", 1)
        ensure_option("rb_accounting_basis", "accruals", "Accruals (traditional) basis", 2)
        print("[Property Income] Seeded rental-business section: 5 questions")

        -- ── Property details (asked once PER property) ──────────────────────
        local pd_id = ensure_category("property-details", "Property details",
            "Details about this specific property", "home", 1, "property")
        if pd_id then
            ensure_question(pd_id, { question_key = "prop_address", label = "Property address",
                question_type = "address", is_required = true, display_order = 1 })
            ensure_question(pd_id, { question_key = "prop_let_type", label = "What kind of let is this?",
                question_type = "single_select", is_required = true, display_order = 2 })
            ensure_question(pd_id, { question_key = "prop_ownership_share", label = "Your ownership share (%)",
                question_type = "percentage", is_required = false, display_order = 3,
                help_text = "100% unless you own the property jointly", placeholder = "100" })
            ensure_question(pd_id, { question_key = "prop_furnished", label = "Is it let furnished?",
                question_type = "boolean", is_required = false, display_order = 4 })
            ensure_question(pd_id, { question_key = "prop_first_let_date", label = "When was this property first let?",
                question_type = "date", is_required = false, display_order = 5 })
            ensure_question(pd_id, { question_key = "prop_has_mortgage", label = "Is there a mortgage on this property?",
                question_type = "boolean", is_required = false, display_order = 6 })
            ensure_question(pd_id, { question_key = "prop_mortgage_interest_only", label = "Is it an interest-only mortgage?",
                question_type = "boolean", is_required = false, display_order = 7 })
        end
        ensure_option("prop_let_type", "residential", "Residential letting", 1)
        ensure_option("prop_let_type", "fhl", "Furnished holiday let", 2)
        ensure_option("prop_let_type", "commercial", "Commercial property", 3)
        ensure_option("prop_let_type", "rent_a_room", "Rent-a-room in my own home", 4)
        ensure_rule("prop_mortgage_interest_only", "prop_has_mortgage", "Show if property has a mortgage", "equals", "true")
        print("[Property Income] Seeded property-details section: 7 questions, 1 rule")
    end,
}
