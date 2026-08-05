--[[
  SA103F Self-employment — completion of the missing boxes.

  The existing self-employment-system seed covers turnover, expenses
  (with disallowable pairs), capital allowances (via the CA grid),
  balance sheet and business details. It does NOT cover:

    * Class 4 NIC exemption / adjustment (boxes 100-102)
    * Adjustment for change of basis (basis-period reform)
    * Loss offset options (boxes 77-79)

  These are per-tax-year TOTALS across the taxpayer's whole
  self-employment position — NOT per-business — so year-scoped
  under context='self_employment' matches the paper form's shape.

  Structure

    Category 1 — sa103f-class4-nic (3 questions)
      Boxes 100, 101, 102 — Class 4 NIC exemption reason /
      adjustment / already paid.

    Category 2 — sa103f-basis-reform (3 questions)
      Boxes 60-73 basis-period reform transition — spreading of
      transition profit, elections. Some already covered by
      transitional_profit_* line categories on the business side;
      this covers the year-total electives.

    Category 3 — sa103f-loss-offset (3 questions)
      Boxes 77-79 — loss set against other income this year,
      loss set against income last year (carry-back), post-
      cessation trade losses.

  Modelling

    * profile_categories.context='self_employment' — matches the
      income_type_key so auto-discovery finds it. Year-scoped.

    * No new income type (existing 'self_employment' extended).

    * Companion frontend PR renders `<ContextSections context=
      'self_employment' taxYear={taxYear} />` on the SE hub — one
      block after the businesses list. Same pattern as SA105 on
      the rental hub.

  Idempotency + safety

  - ensure_question / ensure_year_category key on stable strings
    so re-runs touch labels/help_text but never duplicate.
  - Two-step file (safety-net re-run) matching every other SA
    catalog.
  - INSERT-only. No existing self-employment tables or seeds
    touched.

  Only executed when PROJECT_CODE includes 'tax_copilot'.
]]

local db = require("lapis.db")
local MigrationUtils = require "helper.migration-utils"

local function seed_sa103f_completion()
    local function nn(v) return v ~= nil and v or db.NULL end

    local function ensure_year_category(slug, name, description, icon, display_order)
        local exists = db.select("id FROM profile_categories WHERE slug = ?", slug)
        if exists and #exists > 0 then
            db.query([[
                UPDATE profile_categories
                   SET name = ?, description = ?, icon = ?, display_order = ?,
                       context = 'self_employment',
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
            VALUES (?, 0, ?, ?, ?, ?, ?, 'self_employment', 'year', NULL,
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

    -- ── Category 1: Class 4 NIC ─────────────────────────────────────
    local c4_id = ensure_year_category(
        "sa103f-class4-nic",
        "Class 4 National Insurance",
        "SA103F boxes 100-102. Class 4 NIC exemption / adjustment. Actual Class 4 LIABILITY box 4 is on SA110 — this section captures the reason/adjustment.",
        "briefcase", 20)
    if c4_id then
        ensure_question(c4_id, { question_key = "sa103f_class4_exemption_reason",
            label = "Class 4 NIC exemption reason (box 100)",
            question_type = "long_text", is_required = false, display_order = 1,
            help_text = "Explain why you're claiming exemption from Class 4 NIC (e.g. state pension age reached during year, non-resident trader)." })
        ensure_question(c4_id, { question_key = "sa103f_class4_adjustment",
            label = "Adjustment to profits chargeable to Class 4 NIC (box 101)",
            question_type = "currency", is_required = false, display_order = 2,
            help_text = "Any adjustment to bring profits in line with the Class 4 charge base — e.g. removing income already NIC'd via Class 1." })
        ensure_question(c4_id, { question_key = "sa103f_class4_already_paid",
            label = "Class 4 NIC already paid via PAYE / other (box 102)",
            question_type = "currency", is_required = false, display_order = 3 })
    end

    -- ── Category 2: Basis-period reform / change of basis ───────────
    local br_id = ensure_year_category(
        "sa103f-basis-reform",
        "Basis-period reform adjustments",
        "SA103F basis-period reform (2023-24 transition). Elections and spreading of transition profit — check helpsheet HS252.",
        "briefcase", 21)
    if br_id then
        ensure_question(br_id, { question_key = "sa103f_change_of_basis_adjustment",
            label = "Adjustment for change of basis (transition to tax year basis)",
            question_type = "currency", is_required = false, display_order = 1,
            help_text = "One-off adjustment from the 2023-24 transition to the tax year basis (basis-period reform). Positive = additional taxable profit, negative = reduction." })
        ensure_question(br_id, { question_key = "sa103f_transition_profit_election",
            label = "Election to accelerate transition profit into this year",
            question_type = "boolean", is_required = false, display_order = 2,
            help_text = "By default transition profits from the 2023-24 reform spread over 5 years. Tick to accelerate the remaining amount into this tax year." })
        ensure_question(br_id, { question_key = "sa103f_farmers_averaging_claim",
            label = "Claim farmers' or creators' averaging",
            question_type = "boolean", is_required = false, display_order = 3,
            help_text = "Averaging spreads profits over 2 or 5 years — available to farmers, market gardeners and creators of literary/artistic work." })
    end

    -- ── Category 3: Loss offset options ─────────────────────────────
    local loss_id = ensure_year_category(
        "sa103f-loss-offset",
        "Loss offset options",
        "SA103F boxes 77-79. Options for using self-employment losses against OTHER income (not just future self-employment profits).",
        "briefcase", 22)
    if loss_id then
        ensure_question(loss_id, { question_key = "sa103f_loss_offset_against_income",
            label = "Loss offset against total income this year (box 77)",
            question_type = "currency", is_required = false, display_order = 1,
            help_text = "Use this year's trading loss to reduce your OTHER income (salary, dividends, etc.). Rules limit this to £50k / 25% of income under 'sideways loss relief cap' — see HS227." })
        ensure_question(loss_id, { question_key = "sa103f_loss_carried_back",
            label = "Loss carried back to previous year (box 78)",
            question_type = "currency", is_required = false, display_order = 2,
            help_text = "This year's loss set against income of the PRIOR tax year (triggers repayment of tax already paid)." })
        ensure_question(loss_id, { question_key = "sa103f_post_cessation_loss",
            label = "Post-cessation trade losses (box 79)",
            question_type = "currency", is_required = false, display_order = 3,
            help_text = "Losses incurred AFTER you stopped trading — a bad-debt written off, for example." })
    end

    print("[SA103F Completion] Seeded 3 year-scoped categories (9 questions) under context='self_employment'")
end

return {
    [1] = seed_sa103f_completion,
    [2] = seed_sa103f_completion,
}
