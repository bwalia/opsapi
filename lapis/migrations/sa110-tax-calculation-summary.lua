--[[
  SA110 Tax Calculation Summary — Profile Builder catalog.

  Ports HMRC's SA110 form (17 boxes across 6 sections) into the unified
  Profile Builder store so /my-income/sa110 can be served by the same
  engine as dividends, salary and pension_payments.

  Structure (from the SA110 2026 PDF — tax year 2025-26):

    Section 1 — Self Assessment (boxes 1, 2, 3, 3.1, 4, 4.1, 5, 6)
      Total tax due / overpaid, Student & Postgraduate Loan
      repayments, Class 2 & 4 NICs, CGT, Pension charges.
      All currency.

    Section 2 — Underpaid tax and other debts (boxes 7, 8, 9)
      PAYE Coding Notice figures — earlier-year underpayment,
      current-year underpayment, outstanding debt. All currency.

    Section 3 — Payments on account (boxes 10, 11)
      Box 10 is an X-in-the-box claim (boolean); box 11 is the
      reduced first-payment amount (currency).

    Section 4 — Blind person's + married couple's surplus allowance
      (boxes 12, 13). Both currency. Surplus transferred from spouse
      or civil partner.

    Section 5 — Adjustments to tax due (boxes 14, 15, 16)
      Increase / decrease from earlier-year adjustments, and any
      2026-27 repayment claimed now. All currency.

    Section 6 — Any other information (box 17)
      Free text (long_text) — box 17 on TC 2, "Please give any
      other information in this space".

  Modelling choices — matches the dividends pattern (year-scoped
  answers, one category per form section):

    * profile_categories.context = 'sa110'
    * answer_scope = 'year' (no user_profile_entities row —
                             a single set of answers per tax year)
    * entity_type = NULL

  Total: 1 income_types row + 6 profile_categories + 17 profile_questions.

  Idempotency: keyed on income_type_key + category slug + question_key,
  same convention as every other tax_copilot seed. Re-running touches
  labels/help_text/order but never duplicates or resurrects admin-
  archived rows.

  Only executed when PROJECT_CODE includes 'tax_copilot'.
]]

local db = require("lapis.db")
local cjson = require("cjson")
local MigrationUtils = require "helper.migration-utils"

-- Seed body extracted to module scope so a re-run step ([2]) can call
-- it. Every ensure_* helper is idempotent; a fresh env where step [1]
-- fully succeeded treats [2] as a no-op.
local function seed_sa110_catalog()
    -- Nil-safe helpers — coerce nil description / nil icon / nil help
    -- text to db.NULL BEFORE the db.query call. Lua truncates varargs
    -- at the first nil (`{...}` stops there), so passing nil in the
    -- middle would silently drop trailing placeholders. Same fix that
    -- landed on salary-profile-builder-catalog.lua after the incident
    -- there.
    local function nn(v) return v ~= nil and v or db.NULL end

    local function ensure_income_type(key, display_name, description)
        local exists = db.select("id FROM income_types WHERE income_type_key = ?", key)
        if exists and #exists > 0 then
            db.query([[
                UPDATE income_types
                   SET display_name = ?, description = ?,
                       allows_manual_entry = false,
                       is_active = true, updated_at = NOW()
                 WHERE income_type_key = ?
            ]], display_name, nn(description), key)
            return
        end
        db.query([[
            INSERT INTO income_types
                (uuid, income_type_key, display_name, description,
                 required_documents, allows_manual_entry,
                 keyword_rules, category_affinity, rules_markdown,
                 hmrc_mapping, display_order, is_active, namespace_id,
                 created_at, updated_at)
            VALUES (?, ?, ?, ?,
                    '[]'::jsonb, false,
                    '[]'::jsonb, '{}'::jsonb, NULL,
                    ?::jsonb, 90, true, NULL, NOW(), NOW())
        ]], MigrationUtils.generateUUID(), key, display_name, nn(description),
            cjson.encode({ sa110_form = "TC1-TC2" }))
    end

    local function ensure_category(slug, name, description, icon, display_order)
        local exists = db.select("id FROM profile_categories WHERE slug = ?", slug)
        if exists and #exists > 0 then
            db.query([[
                UPDATE profile_categories
                   SET name = ?, description = ?, icon = ?, display_order = ?,
                       context = 'sa110',
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
            VALUES (?, 0, ?, ?, ?, ?, ?, 'sa110', 'year', NULL,
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

    -- ── Income type ─────────────────────────────────────────────────
    -- allows_manual_entry=false: /my-incomes rows typed 'sa110' would
    -- be counted as trading income (wrong direction — SA110 is a
    -- calculation summary, not an income source). Setting the flag
    -- keeps SA110 off the flat-entry legacy path; the profile-builder
    -- store is authoritative from day one.
    ensure_income_type(
        "sa110",
        "Tax calculation summary (SA110)",
        "HMRC's SA110 supplementary form — enter the total tax, NICs, Student & Postgraduate Loan repayments, CGT, pension charges and any payments-on-account claims for the year. Use the working sheet in the 'Tax calculation summary notes' to derive the box values."
    )

    -- ── Section 1: Self Assessment ─────────────────────────────────
    local sa_id = ensure_category(
        "sa110-self-assessment", "Self Assessment",
        "Total tax, NICs, Student & Postgraduate Loan repayments, CGT, and pension charges due or overpaid for the year.",
        "pound-sign", 1)
    if sa_id then
        ensure_question(sa_id, { question_key = "sa110_total_tax_due",
            label = "Total tax, NICs, Student Loan and Postgraduate Loan repayments due (box 1)",
            question_type = "currency", is_required = false, display_order = 1,
            help_text = "The total tax figure BEFORE any payments on account. If the working sheet produces a negative number, enter it in the 'overpaid' box below instead." })
        ensure_question(sa_id, { question_key = "sa110_total_tax_overpaid",
            label = "Total tax, NICs, Student Loan and Postgraduate Loan repayments overpaid (box 2)",
            question_type = "currency", is_required = false, display_order = 2,
            help_text = "Only fill in if the working sheet shows tax overpaid — this triggers a refund rather than a balance due." })
        ensure_question(sa_id, { question_key = "sa110_student_loan_due",
            label = "Student Loan repayment due (box 3)",
            question_type = "currency", is_required = false, display_order = 3 })
        ensure_question(sa_id, { question_key = "sa110_postgraduate_loan_due",
            label = "Postgraduate Loan repayment due (box 3.1)",
            question_type = "currency", is_required = false, display_order = 4 })
        ensure_question(sa_id, { question_key = "sa110_class4_nics_due",
            label = "Class 4 NICs due (box 4)",
            question_type = "currency", is_required = false, display_order = 5,
            help_text = "Only applies to self-employed profits above the Lower Profits Limit." })
        ensure_question(sa_id, { question_key = "sa110_class2_nics_due",
            label = "Class 2 NICs due (box 4.1)",
            question_type = "currency", is_required = false, display_order = 6 })
        ensure_question(sa_id, { question_key = "sa110_capital_gains_tax_due",
            label = "Capital Gains Tax due (box 5)",
            question_type = "currency", is_required = false, display_order = 7 })
        ensure_question(sa_id, { question_key = "sa110_pension_charges_due",
            label = "Pension charges due (box 6)",
            question_type = "currency", is_required = false, display_order = 8,
            help_text = "Annual allowance charge, lifetime allowance charge, unauthorised payments — see the SA110 notes." })
    end

    -- ── Section 2: Underpaid tax and other debts ────────────────────
    local ut_id = ensure_category(
        "sa110-underpaid-tax", "Underpaid tax and other debts",
        "Figures from your P2 PAYE Coding Notice — earlier-year and current-year underpayments, plus any outstanding debt included in your code.",
        "pound-sign", 2)
    if ut_id then
        ensure_question(ut_id, { question_key = "sa110_underpaid_earlier_years",
            label = "Underpaid tax for earlier years in your 2025-26 code (box 7)",
            question_type = "currency", is_required = false, display_order = 1,
            help_text = "Shown as 'amount of underpaid tax for earlier years' on your P2." })
        ensure_question(ut_id, { question_key = "sa110_underpaid_2025_26",
            label = "Underpaid tax for 2025-26 in your 2026-27 code (box 8)",
            question_type = "currency", is_required = false, display_order = 2,
            help_text = "Shown as 'estimated underpayment for 2025-26' on your P2." })
        ensure_question(ut_id, { question_key = "sa110_outstanding_debt",
            label = "Outstanding debt in your 2025-26 code (box 9)",
            question_type = "currency", is_required = false, display_order = 3,
            help_text = "The debt figure from your P2." })
    end

    -- ── Section 3: Payments on account ──────────────────────────────
    local poa_id = ensure_category(
        "sa110-payments-on-account", "Payments on account",
        "Claim to reduce your 2026-27 payments on account and (if so) your first reduced payment.",
        "pound-sign", 3)
    if poa_id then
        ensure_question(poa_id, { question_key = "sa110_reduce_poa_claim",
            label = "Claim to reduce 2026-27 payments on account (box 10)",
            question_type = "boolean", is_required = false, display_order = 1,
            help_text = "Tick this box if you're claiming to reduce your 2026-27 payments on account. Say WHY in box 17 (Any other information)." })
        ensure_question(poa_id, { question_key = "sa110_first_poa_amount",
            label = "Your first payment on account for 2026-27, including pence (box 11)",
            question_type = "currency", is_required = false, display_order = 2,
            help_text = "The reduced amount you're claiming. Only needed if you ticked the box above." })
    end

    -- ── Section 4: Blind person's + married couple's surplus ────────
    local sa_al_id = ensure_category(
        "sa110-surplus-allowances", "Blind person's and married couple's surplus allowance",
        "Enter the surplus allowance transferred from your spouse or civil partner.",
        "pound-sign", 4)
    if sa_al_id then
        ensure_question(sa_al_id, { question_key = "sa110_blind_person_surplus",
            label = "Blind person's surplus allowance you can have (box 12)",
            question_type = "currency", is_required = false, display_order = 1 })
        ensure_question(sa_al_id, { question_key = "sa110_married_couple_surplus",
            label = "Married couple's surplus allowance you can have (box 13)",
            question_type = "currency", is_required = false, display_order = 2,
            help_text = "Only if you or your spouse or civil partner were born before 6 April 1935." })
    end

    -- ── Section 5: Adjustments to tax due ───────────────────────────
    local adj_id = ensure_category(
        "sa110-adjustments", "Adjustments to tax due",
        "Adjustments calculated by reference to an earlier year (averaging for farmers/creators, loss carry-back, etc.).",
        "pound-sign", 5)
    if adj_id then
        ensure_question(adj_id, { question_key = "sa110_increase_earlier_year",
            label = "Increase in tax due because of adjustments to an earlier year (box 14)",
            question_type = "currency", is_required = false, display_order = 1 })
        ensure_question(adj_id, { question_key = "sa110_decrease_earlier_year",
            label = "Decrease in tax due because of adjustments to an earlier year (box 15)",
            question_type = "currency", is_required = false, display_order = 2 })
        ensure_question(adj_id, { question_key = "sa110_repayment_2026_27_now",
            label = "Any 2026-27 repayment you're claiming now (box 16)",
            question_type = "currency", is_required = false, display_order = 3,
            help_text = "A credit that appears on your Self Assessment statement of account and is set against other amounts to be paid — doesn't affect boxes 1 to 6." })
    end

    -- ── Section 6: Any other information ────────────────────────────
    local other_id = ensure_category(
        "sa110-other-info", "Any other information",
        "Free-form notes to HMRC — use this to explain any reduced payment on account claim, unusual adjustments, or context they need.",
        "pound-sign", 6)
    if other_id then
        ensure_question(other_id, { question_key = "sa110_other_information",
            label = "Please give any other information in this space (box 17)",
            question_type = "long_text", is_required = false, display_order = 1,
            help_text = "Required if you ticked box 10 (reduced payments-on-account claim) — HMRC wants a reason. Otherwise optional." })
    end

    print("[SA110] Seeded income_types row + 6 categories + 17 questions under context='sa110' (answer_scope='year')")
end

return {
    -- =========================================================================
    -- 1. Original seed pass. Registered as 766 in migrations.lua.
    -- =========================================================================
    [1] = seed_sa110_catalog,

    -- =========================================================================
    -- 2. Re-run pass. Registered as 767 in migrations.lua. Safety net
    --    for future edits to this file (same convention as the pension
    --    catalog's 764 and the salary catalog's 760). Fresh envs where
    --    [1] fully succeeded treat [2] as an idempotent no-op.
    -- =========================================================================
    [2] = seed_sa110_catalog,
}
