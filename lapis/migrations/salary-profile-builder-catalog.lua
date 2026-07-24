--[[
  Salary / Employment (SA102) — Profile Builder catalog.

  Phase 1 of the profile-builder unification (see the diy-tax-return-uk
  repo's docs/PROFILE_BUILDER_UNIFICATION_PLAN.md). Ports the 7 form
  sections and ~42 fields currently held in tax_form_sections
  (income_type_key='salary') into the unified profile_categories +
  profile_questions store, so /my-income/salary can be served by the
  same engine as rental / self-employment / overseas / dividends.

  Modelling choices — copied straight from the self-employment seed
  (property-income-system.lua [7] → self-employment-system.lua [6])
  which is the reference implementation for "list of entities, each
  with drill-down questions":

    1. Employments become user_profile_entities rows with
       entity_type='employment'. The user_profile_entities table was
       built generic for exactly this reuse — no schema change.

    2. Per-employment questions are Profile Builder categories with
       context='employment', answered with entity_uuid scope
       (answer_scope='entity', entity_type='employment'). We set both
       explicitly at seed time because dynamic-answer-scope.lua [5]'s
       backfill only knows about the older contexts (property,
       business, overseas_property).

    3. One PROFILE CATEGORY per section from the tax_form_sections
       catalogue — 7 categories, each with the section's fields as
       profile_questions. ContextSections renders each as its own
       card, which gives the same visual grouping the FormRecordsPage
       had for free.

  What this migration does NOT do:
    - It does NOT delete or archive tax_form_sections rows for salary
      (Phase 3's job, after the profile-builder path has been live
      in prod for 14+ days).
    - It does NOT flip the frontend engine for salary (that's driven
      by the NEXT_PUBLIC_INCOME_ENGINE_SALARY env var per env — see
      docs/PROFILE_BUILDER_UNIFICATION_PLAN.md §4).
    - It does NOT backfill existing user data
      (`salary-profile-builder-backfill.lua`, the sibling migration
      in this PR, does that — kept separate so a re-run of one
      doesn't force the other).

  Idempotency: keyed on category slug + question_key, same convention
  as every other profile-builder seed. Re-running touches labels /
  ordering but never duplicates rows or resurrects admin-archived
  ones.

  Only executed when PROJECT_CODE includes 'tax_copilot'.

  Type mapping from tax_form_sections config.fields → profile_questions:

    text      → short_text
    money     → currency
    number    → number
    date      → date
    boolean   → boolean
    textarea  → long_text

  show_if visibility rules become profile_question_rules rows
  (rule_type='visibility', operator='equals', expected_value='true').
]]

local db = require("lapis.db")
local MigrationUtils = require "helper.migration-utils"

return {
    -- =========================================================================
    -- 1. Seed the 7 employment categories + ~42 questions + visibility rules.
    --    Structured as one step so a re-run either succeeds fully or leaves
    --    the DB unchanged (each ensure_* is idempotent, but the whole set
    --    is a package).
    -- =========================================================================
    [1] = function()
        -- Same helpers as property-income-system.lua [7] and
        -- self-employment-system.lua [6]. Duplicated here (not extracted)
        -- because each seed migration is self-contained — future refactor
        -- can lift to a shared migration utility once we have 3+ callers.
        --
        -- Extended vs the reference: writes answer_scope='entity' and
        -- entity_type='employment' explicitly. The reference relied on
        -- dynamic-answer-scope.lua [5]'s backfill which only knows about
        -- the older contexts; new contexts (like employment) must set
        -- the columns themselves at seed time.
        local function ensure_category(slug, name, description, icon, display_order, context)
            local exists = db.select("id FROM profile_categories WHERE slug = ?", slug)
            if exists and #exists > 0 then
                db.query([[
                    UPDATE profile_categories
                       SET name = ?, description = ?, icon = ?, display_order = ?,
                           context = ?, answer_scope = 'entity', entity_type = 'employment',
                           is_active = true, is_archived = false, updated_at = NOW()
                     WHERE slug = ?
                ]], name, description, icon, display_order, context, slug)
                return exists[1].id
            end
            db.query([[
                INSERT INTO profile_categories
                    (uuid, namespace_id, name, slug, description, icon,
                     display_order, context, answer_scope, entity_type,
                     is_active, is_archived, created_at, updated_at)
                VALUES (?, 0, ?, ?, ?, ?, ?, ?, 'entity', 'employment',
                        true, false, NOW(), NOW())
            ]], MigrationUtils.generateUUID(), name, slug, description, icon,
                display_order, context)
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
                ]], cat_id, q.label, q.question_type, q.is_required, q.display_order,
                    q.help_text or "", q.placeholder or "", q.question_key)
                return exists[1].id
            end
            db.query([[
                INSERT INTO profile_questions
                    (uuid, category_id, question_key, label, question_type, is_required,
                     display_order, help_text, placeholder, is_active, version,
                     created_at, updated_at)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, true, 1, NOW(), NOW())
            ]], MigrationUtils.generateUUID(), cat_id, q.question_key, q.label,
                q.question_type, q.is_required, q.display_order,
                q.help_text or "", q.placeholder or "")
            local row = db.select("id FROM profile_questions WHERE question_key = ?", q.question_key)
            return row and row[1] and row[1].id or nil
        end

        local function ensure_rule(target_key, source_key, rule_name, operator, expected_value)
            local tgt = db.select("id FROM profile_questions WHERE question_key = ?", target_key)
            local src = db.select("id FROM profile_questions WHERE question_key = ?", source_key)
            if not tgt or #tgt == 0 or not src or #src == 0 then return end
            local exists = db.select(
                "id FROM profile_question_rules WHERE question_id = ? AND source_question_id = ?",
                tgt[1].id, src[1].id)
            if exists and #exists > 0 then return end
            db.query([[
                INSERT INTO profile_question_rules
                    (uuid, question_id, rule_name, rule_type, operator,
                     source_question_id, expected_value, logic_group,
                     is_active, created_at, updated_at)
                VALUES (?, ?, ?, 'visibility', ?, ?, ?, 'AND', true, NOW(), NOW())
            ]], MigrationUtils.generateUUID(), tgt[1].id, rule_name, operator,
                src[1].id, expected_value)
        end

        -- ── Category 1: Employment details ──────────────────────────
        -- Mirrors tax_form_sections.employment_details. Includes the
        -- title + subtitle fields the list view uses (employer_name,
        -- paye_reference) — the frontend's list card reads the answers
        -- to these two questions by their known question_keys.
        local ed_id = ensure_category(
            "employment-details", "Employment details",
            "Who you worked for — from your P60, P45 or payslips.",
            "briefcase", 1, "employment")
        if ed_id then
            ensure_question(ed_id, { question_key = "emp_employer_name",
                label = "Employer's name", question_type = "short_text",
                is_required = true, display_order = 1 })
            ensure_question(ed_id, { question_key = "emp_paye_reference",
                label = "Employer's PAYE tax reference (NNN/XXXXXX)",
                question_type = "short_text", is_required = true, display_order = 2,
                help_text = "On your P60 or P45 — three numbers, a slash, then letters and numbers." })
            ensure_question(ed_id, { question_key = "emp_start_date",
                label = "Date employment started", question_type = "date",
                is_required = false, display_order = 3 })
            ensure_question(ed_id, { question_key = "emp_end_date",
                label = "Date employment ceased", question_type = "date",
                is_required = false, display_order = 4 })
            ensure_question(ed_id, { question_key = "emp_is_director",
                label = "Were you a company director?", question_type = "boolean",
                is_required = false, display_order = 5 })
            ensure_question(ed_id, { question_key = "emp_director_ceased_date",
                label = "Date ceased being a director", question_type = "date",
                is_required = false, display_order = 6 })
            ensure_question(ed_id, { question_key = "emp_is_close_company",
                label = "Is this a close company?", question_type = "boolean",
                is_required = false, display_order = 7,
                help_text = "A company controlled by 5 or fewer people (or by its directors)." })
        end
        ensure_rule("emp_director_ceased_date", "emp_is_director",
            "Show when user was a director", "equals", "true")

        -- ── Category 2: Close company details ───────────────────────
        local cc_id = ensure_category(
            "employment-close-company", "Close company details",
            nil, "briefcase", 2, "employment")
        if cc_id then
            ensure_question(cc_id, { question_key = "emp_cc_registered_number",
                label = "Registered number", question_type = "short_text",
                is_required = false, display_order = 1 })
            ensure_question(cc_id, { question_key = "emp_cc_dividends",
                label = "Dividends you received from this close company",
                question_type = "currency", is_required = false, display_order = 2 })
            ensure_question(cc_id, { question_key = "emp_cc_shareholding_percent",
                label = "Percentage shareholding in this close company",
                question_type = "percentage", is_required = false, display_order = 3 })
        end
        ensure_rule("emp_cc_registered_number", "emp_is_close_company",
            "Show when close company", "equals", "true")
        ensure_rule("emp_cc_dividends", "emp_is_close_company",
            "Show when close company", "equals", "true")
        ensure_rule("emp_cc_shareholding_percent", "emp_is_close_company",
            "Show when close company", "equals", "true")

        -- ── Category 3: Income ───────────────────────────────────────
        local inc_id = ensure_category(
            "employment-income", "Income",
            "From your P60 (or P45 if you left during the year).",
            "briefcase", 3, "employment")
        if inc_id then
            ensure_question(inc_id, { question_key = "emp_pay_before_tax",
                label = "Pay from this employment before tax was taken off",
                question_type = "currency", is_required = false, display_order = 1 })
            ensure_question(inc_id, { question_key = "emp_payrolled_benefits",
                label = "Payrolled benefits included above which affect your student loan repayments",
                question_type = "currency", is_required = false, display_order = 2 })
            ensure_question(inc_id, { question_key = "emp_uk_tax_taken_off",
                label = "UK tax taken off", question_type = "currency",
                is_required = false, display_order = 3 })
            ensure_question(inc_id, { question_key = "emp_tips_not_on_p60",
                label = "Tips and other payments not on your P60",
                question_type = "currency", is_required = false, display_order = 4 })
        end

        -- ── Category 4: Benefits ─────────────────────────────────────
        local ben_id = ensure_category(
            "employment-benefits", "Benefits",
            "These amounts will be on form P11D from your employer.",
            "briefcase", 4, "employment")
        if ben_id then
            local benefits = {
                { "emp_ben_company_cars",          "Company cars",                                            1 },
                { "emp_ben_fuel_company_cars",     "Fuel for company cars",                                   2 },
                { "emp_ben_company_vans",          "Company vans",                                            3 },
                { "emp_ben_fuel_company_vans",     "Fuel for company vans",                                   4 },
                { "emp_ben_travel_subsistence",    "Travel and subsistence",                                  5 },
                { "emp_ben_entertaining",          "Entertaining",                                            6 },
                { "emp_ben_private_medical",       "Private medical and dental insurance",                    7 },
                { "emp_ben_telephone",             "Telephone",                                               8 },
                { "emp_ben_professional_fees",     "Professional fees & subscriptions paid by employer",      9 },
                { "emp_ben_vouchers_credit_cards", "Vouchers and credit cards",                              10 },
                { "emp_ben_excess_mileage",        "Excess mileage allowance",                               11 },
                { "emp_ben_goods_assets",          "Goods and other assets provided by employer",            12 },
                { "emp_ben_accommodation",         "Accommodation provided by employer",                     13 },
                { "emp_ben_other",                 "Other benefits",                                         14 },
                { "emp_ben_expenses_payments",     "Expenses payments received",                             15 },
            }
            for _, b in ipairs(benefits) do
                ensure_question(ben_id, { question_key = b[1], label = b[2],
                    question_type = "currency", is_required = false, display_order = b[3] })
            end
        end

        -- ── Category 5: Expenses ─────────────────────────────────────
        local exp_id = ensure_category(
            "employment-expenses", "Expenses",
            "Costs of doing your job that your employer didn't reimburse.",
            "briefcase", 5, "employment")
        if exp_id then
            local expenses = {
                { "emp_exp_business_travel",     "Business travel",                            1 },
                { "emp_exp_hotel_meal",          "Hotel and meal expenses",                    2 },
                { "emp_exp_fixed_deductions",    "Fixed deductions for expenses",              3 },
                { "emp_exp_professional_fees",   "Professional fees and subscriptions",        4 },
                { "emp_exp_tools_clothes",       "Cost of tools and work clothes",             5 },
                { "emp_exp_vehicle",             "Vehicle expenses",                           6 },
                { "emp_exp_mileage_shortfall",   "Mileage allowance shortfall",                7 },
                { "emp_exp_other_capital",       "Other expenses and capital allowances",      8 },
            }
            for _, e in ipairs(expenses) do
                ensure_question(exp_id, { question_key = e[1], label = e[2],
                    question_type = "currency", is_required = false, display_order = e[3] })
            end
        end

        -- ── Category 6: Foreign earnings ─────────────────────────────
        local for_id = ensure_category(
            "employment-foreign", "Foreign earnings and deductions",
            nil, "briefcase", 6, "employment")
        if for_id then
            ensure_question(for_id, { question_key = "emp_foreign_seafarers",
                label = "Seafarers' earnings deduction", question_type = "currency",
                is_required = false, display_order = 1 })
            ensure_question(for_id, { question_key = "emp_foreign_not_taxable",
                label = "Foreign earnings not taxable in the UK",
                question_type = "currency", is_required = false, display_order = 2 })
            ensure_question(for_id, { question_key = "emp_foreign_tax_no_credit",
                label = "Foreign tax for which tax credit relief not claimed",
                question_type = "currency", is_required = false, display_order = 3 })
            ensure_question(for_id, { question_key = "emp_foreign_exempt_pension",
                label = "Exempt employers' contributions to an overseas pension scheme",
                question_type = "currency", is_required = false, display_order = 4 })
        end

        -- ── Category 7: Notes ────────────────────────────────────────
        local notes_id = ensure_category(
            "employment-notes", "Additional information",
            nil, "briefcase", 7, "employment")
        if notes_id then
            ensure_question(notes_id, { question_key = "emp_tax_return_note",
                label = "Additional text note for your tax return",
                question_type = "long_text", is_required = false, display_order = 1,
                help_text = "Anything HMRC should know about this employment — goes in the 'any other information' box." })
        end

        print("[Salary → Profile Builder] Seeded 7 categories, 42 questions, 4 visibility rules under entity_type='employment'")
    end,
}
