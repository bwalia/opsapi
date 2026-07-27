--[[
  SA106 Foreign — non-property income sections.

  Closes another HIGH-priority audit gap: the existing
  overseas-property-system seed covers foreign PROPERTY only. All
  other foreign-income boxes on SA106 (savings interest, dividends
  above the £500 SA100 threshold, pensions, life insurance gains,
  Foreign Tax Credit Relief pairing rows) are missing today —
  anyone with a foreign brokerage account or overseas pension can't
  file cleanly.

  Structure — the parts of SA106 NOT already covered by
  overseas-property-system.lua:

    Section 1 — Unremittable income (2 questions)
      Boxes 1, 2 — income not remitted, election under s842.

    Section 2 — Foreign savings interest (3 questions)
      Boxes 3, 4, 5 — total interest, tax deducted, foreign tax
      credit relief claimed.

    Section 3 — Dividends from foreign companies (3 questions)
      Boxes 6, 7, 8 — total dividends, foreign tax deducted, FTCR
      claimed.

    Section 4 — Overseas pensions and social security benefits
                (5 questions)
      Boxes 11, 12, 13, 14 — gross overseas pension, UK tax
      deducted, 10% deduction claim, foreign tax deducted, FTCR
      claimed.

    Section 5 — Foreign tax paid on employment / other income
                (2 questions)
      Boxes 15, 16 — total tax paid, FTCR claim.

    Section 6 — Gains on foreign life insurance policies
                (3 questions)
      Boxes 43, 44, 45 — gain, tax deducted, years held.

  NOT included (already covered by overseas-property-system.lua):
    - Section 7 Income from land and property abroad (boxes 14-33
      of SA106 page F3-F4).

  Modelling choices

    * NEW income_type_key='foreign_income' with linked_form_title
      ='SA106'. Auto-discovery renders /my-income/foreign_income
      with zero frontend code (see the auto-discovery PR).

    * profile_categories.context='foreign_income',
      answer_scope='year', entity_type=NULL. Single set of answers
      per tax year (SA106 non-property boxes are portfolio-wide
      totals — one foreign-interest total for the year across all
      foreign banks).

    * allows_manual_entry=false — SA106 is a supplementary form,
      not a simple income entry.

    * Distinct from the existing 'overseas_property' income type
      which stays focused on foreign PROPERTY. Both types reference
      SA106 (different sections) via linked_form_title.

  Scalability: admin can add more SA106 sections (should HMRC add
  one) via /admin/profile-builder/categories with
  context='foreign_income' — zero code deploy.

  Only executed when PROJECT_CODE includes 'tax_copilot'.
]]

local db = require("lapis.db")
local cjson = require("cjson")
local MigrationUtils = require "helper.migration-utils"

local function seed_sa106_foreign()
    local function nn(v) return v ~= nil and v or db.NULL end

    local function ensure_income_type()
        local key = "foreign_income"
        local exists = db.select("id FROM income_types WHERE income_type_key = ?", key)
        if exists and #exists > 0 then
            db.query([[
                UPDATE income_types
                   SET display_name = ?, description = ?,
                       allows_manual_entry = false,
                       is_active = true, updated_at = NOW(),
                       linked_form_title = COALESCE(linked_form_title, ?),
                       linked_form_description = COALESCE(linked_form_description, ?),
                       linked_form_weblink = COALESCE(linked_form_weblink, ?)
                 WHERE income_type_key = ?
            ]],
                "Foreign income (SA106)",
                "Foreign savings interest, dividends above the £500 UK threshold, overseas pensions, and Foreign Tax Credit Relief. If you have foreign PROPERTY income use the 'Overseas property' section instead.",
                "SA106",
                "These fields map directly to the SA106 Foreign form (sections F1-F2 and F5 — foreign PROPERTY is captured separately on the overseas property page).",
                "https://assets.publishing.service.gov.uk/media/6874c94af6a03e18e2ca4a3f/SA106-2025.pdf",
                key)
            return
        end
        db.query([[
            INSERT INTO income_types
                (uuid, income_type_key, display_name, description,
                 required_documents, allows_manual_entry,
                 keyword_rules, category_affinity, rules_markdown,
                 hmrc_mapping, display_order, is_active, namespace_id,
                 linked_form_title, linked_form_description, linked_form_weblink,
                 created_at, updated_at)
            VALUES (?, ?, ?, ?,
                    '[]'::jsonb, false,
                    '[]'::jsonb, '{}'::jsonb, NULL,
                    ?::jsonb, 40, true, NULL,
                    ?, ?, ?,
                    NOW(), NOW())
        ]],
            MigrationUtils.generateUUID(), key,
            "Foreign income (SA106)",
            "Foreign savings interest, dividends above the £500 UK threshold, overseas pensions, and Foreign Tax Credit Relief. If you have foreign PROPERTY income use the 'Overseas property' section instead.",
            cjson.encode({ sa106_form = "F1-F2, F5" }),
            "SA106",
            "These fields map directly to the SA106 Foreign form (sections F1-F2 and F5 — foreign PROPERTY is captured separately on the overseas property page).",
            "https://assets.publishing.service.gov.uk/media/6874c94af6a03e18e2ca4a3f/SA106-2025.pdf")
    end

    local function ensure_year_category(slug, name, description, icon, display_order)
        local exists = db.select("id FROM profile_categories WHERE slug = ?", slug)
        if exists and #exists > 0 then
            db.query([[
                UPDATE profile_categories
                   SET name = ?, description = ?, icon = ?, display_order = ?,
                       context = 'foreign_income',
                       answer_scope = 'year',
                       entity_type = NULL,
                       is_active = true, is_archived = false, updated_at = NOW()
                 WHERE slug = ?
            ]], name, nn(description), nn(icon), display_order, slug)
            return exists[1].id
        end
        db.query([[
            INSERT INTO profile_categories
                (uuid, namespace_id, name, slug, description, icon,
                 display_order, context, answer_scope, entity_type,
                 is_active, is_archived, created_at, updated_at)
            VALUES (?, 0, ?, ?, ?, ?, ?, 'foreign_income', 'year', NULL,
                    true, false, NOW(), NOW())
        ]], MigrationUtils.generateUUID(), name, slug, nn(description),
            nn(icon), display_order)
        local row = db.select("id FROM profile_categories WHERE slug = ?", slug)
        return row and row[1] and row[1].id or nil
    end

    local function ensure_question(cat_id, q)
        local exists = db.select("id FROM profile_questions WHERE question_key = ?", q.question_key)
        if exists and #exists > 0 then
            db.query([[
                UPDATE profile_questions
                   SET category_id = ?, label = ?, question_type = ?, is_required = ?,
                       display_order = ?, help_text = ?, placeholder = '',
                       is_active = true, is_archived = false, updated_at = NOW()
                 WHERE question_key = ?
            ]], cat_id, q.label, q.question_type, q.is_required, q.display_order,
                q.help_text or "", q.question_key)
            return exists[1].id
        end
        db.query([[
            INSERT INTO profile_questions
                (uuid, category_id, question_key, label, question_type, is_required,
                 display_order, help_text, placeholder,
                 is_active, version, created_at, updated_at)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, '', true, 1, NOW(), NOW())
        ]], MigrationUtils.generateUUID(), cat_id, q.question_key, q.label,
            q.question_type, q.is_required, q.display_order, q.help_text or "")
    end

    ensure_income_type()

    -- ── Section 1: Unremittable income ──────────────────────────────
    local un_id = ensure_year_category(
        "sa106-unremittable-income",
        "Unremittable overseas income",
        "SA106 boxes 1-2. Income you can't transfer to the UK because of local rules.",
        "globe", 1)
    if un_id then
        ensure_question(un_id, { question_key = "sa106_unremittable_amount",
            label = "Amount of unremittable overseas income (box 1)",
            question_type = "currency", is_required = false, display_order = 1 })
        ensure_question(un_id, { question_key = "sa106_unremittable_s842_claim",
            label = "Claim relief under section 842 ITTOIA 2005? (box 2)",
            question_type = "boolean", is_required = false, display_order = 2,
            help_text = "Tick if you can't bring the income to the UK because of exchange controls or a shortage of foreign currency." })
    end

    -- ── Section 2: Foreign savings interest ─────────────────────────
    local fi_id = ensure_year_category(
        "sa106-foreign-interest",
        "Foreign savings interest",
        "SA106 boxes 3-5. Interest from overseas banks / building societies (above the £2,000 SA100 threshold).",
        "globe", 2)
    if fi_id then
        ensure_question(fi_id, { question_key = "sa106_foreign_interest_gross",
            label = "Gross foreign interest received (box 3)",
            question_type = "currency", is_required = false, display_order = 1,
            help_text = "Total interest before any foreign tax was deducted. Sterling equivalent at the date received." })
        ensure_question(fi_id, { question_key = "sa106_foreign_interest_tax",
            label = "Foreign tax deducted (box 4)",
            question_type = "currency", is_required = false, display_order = 2 })
        ensure_question(fi_id, { question_key = "sa106_foreign_interest_ftcr",
            label = "Foreign Tax Credit Relief claimed (box 5)",
            question_type = "currency", is_required = false, display_order = 3,
            help_text = "The credit HMRC gives you for foreign tax paid — reduces your UK tax bill on the same income (dual-taxation avoidance)." })
    end

    -- ── Section 3: Dividends from foreign companies ─────────────────
    local fd_id = ensure_year_category(
        "sa106-foreign-dividends",
        "Dividends from foreign companies",
        "SA106 boxes 6-8. Dividends from non-UK companies (above the £500 SA100 threshold).",
        "globe", 3)
    if fd_id then
        ensure_question(fd_id, { question_key = "sa106_foreign_dividends_gross",
            label = "Gross foreign dividends received (box 6)",
            question_type = "currency", is_required = false, display_order = 1,
            help_text = "Sterling equivalent, before any foreign withholding tax." })
        ensure_question(fd_id, { question_key = "sa106_foreign_dividends_tax",
            label = "Foreign tax deducted (box 7)",
            question_type = "currency", is_required = false, display_order = 2 })
        ensure_question(fd_id, { question_key = "sa106_foreign_dividends_ftcr",
            label = "Foreign Tax Credit Relief claimed (box 8)",
            question_type = "currency", is_required = false, display_order = 3 })
    end

    -- ── Section 4: Overseas pensions and social security benefits ───
    local fp_id = ensure_year_category(
        "sa106-overseas-pensions",
        "Overseas pensions and social security benefits",
        "SA106 boxes 11-14. Pensions and social security from outside the UK.",
        "globe", 4)
    if fp_id then
        ensure_question(fp_id, { question_key = "sa106_overseas_pension_gross",
            label = "Gross overseas pension received (box 11)",
            question_type = "currency", is_required = false, display_order = 1,
            help_text = "Include state pensions, occupational pensions and private pensions from overseas." })
        ensure_question(fp_id, { question_key = "sa106_overseas_pension_uk_tax",
            label = "UK tax deducted at source (box 12)",
            question_type = "currency", is_required = false, display_order = 2 })
        ensure_question(fp_id, { question_key = "sa106_overseas_pension_10_percent",
            label = "Claim 10% deduction (box 12A)",
            question_type = "boolean", is_required = false, display_order = 3,
            help_text = "Tick if the overseas pension qualifies for the 10% foreign-pension deduction (see helpsheet HS310)." })
        ensure_question(fp_id, { question_key = "sa106_overseas_pension_foreign_tax",
            label = "Foreign tax paid on the pension (box 13)",
            question_type = "currency", is_required = false, display_order = 4 })
        ensure_question(fp_id, { question_key = "sa106_overseas_pension_ftcr",
            label = "Foreign Tax Credit Relief claimed (box 14)",
            question_type = "currency", is_required = false, display_order = 5 })
    end

    -- ── Section 5: Foreign tax on employment/other income ───────────
    local ft_id = ensure_year_category(
        "sa106-foreign-tax-other-income",
        "Foreign tax on employment and other income",
        "SA106 boxes 15-16. Foreign tax paid on income declared elsewhere on your return (employment, self-employment, etc.).",
        "globe", 5)
    if ft_id then
        ensure_question(ft_id, { question_key = "sa106_foreign_tax_on_other_income",
            label = "Total foreign tax paid on income declared elsewhere (box 15)",
            question_type = "currency", is_required = false, display_order = 1 })
        ensure_question(ft_id, { question_key = "sa106_foreign_tax_on_other_ftcr",
            label = "Foreign Tax Credit Relief claim (box 16)",
            question_type = "currency", is_required = false, display_order = 2 })
    end

    -- ── Section 6: Gains on foreign life insurance ──────────────────
    local fl_id = ensure_year_category(
        "sa106-foreign-life-insurance",
        "Gains on foreign life insurance policies",
        "SA106 boxes 43-45. Chargeable-event gains on non-UK life insurance / capital redemption policies.",
        "globe", 6)
    if fl_id then
        ensure_question(fl_id, { question_key = "sa106_foreign_life_gain",
            label = "Total chargeable gain (box 43)",
            question_type = "currency", is_required = false, display_order = 1 })
        ensure_question(fl_id, { question_key = "sa106_foreign_life_tax",
            label = "Foreign tax deducted (box 44)",
            question_type = "currency", is_required = false, display_order = 2 })
        ensure_question(fl_id, { question_key = "sa106_foreign_life_years",
            label = "Number of complete years the policy was held (box 45)",
            question_type = "number", is_required = false, display_order = 3,
            help_text = "Used for top-slicing relief — see HS320." })
    end

    print("[SA106 Foreign] Seeded income_types row + 6 categories + ~18 questions under context='foreign_income' (answer_scope='year')")
end

return {
    [1] = seed_sa106_foreign,
    [2] = seed_sa106_foreign,
}
