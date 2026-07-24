--[[
  SA101 Additional information — every box on the form (pages Ai 1 to
  Ai 4) wired through the Dynamic Profile Builder as the "Other income"
  panel (income_types key 'other'), so admins can rename, reorder,
  disable, add rules, or add entirely new boxes WITHOUT a code deploy.
  Same pattern as the SA108 capital gains seed
  (sa108-capital-gains-questions.lua).

  Source of truth: the SA101 2026 paper form ("Tax year 6 April 2025
  to 5 April 2026 (2025–26)", HMRC 12/25). One profile category per
  boxed section group, in form order:

    Ai1  Other UK income:
           Interest from gilt-edged and other UK securities    boxes 1–3
           Gains from life insurance policies                  boxes 4–11
           Stock dividends, bonus issues, redeemable shares    boxes 12–13.1
           Business receipts taxed as income of earlier year   boxes 14–15
    Ai2  Share schemes and employment lump sums …              boxes 1–15
    Ai2  Other tax reliefs                                     boxes 1–12
    Ai3  Married Couple's Allowance                            boxes 1–11
    Ai3  Income Tax losses and limit on Income Tax relief      boxes 1–6
    Ai4  Pension Savings Tax Charges                           boxes 10–18
    Ai4  Tax avoidance schemes                                 boxes 19–20

  IMPORTANT — box numbering RESTARTS per section group on SA101
  (there are three different "box 1"s). Every question's
  config_json.hmrc_mapping therefore carries a `section` slug
  alongside `box`, and help_text cites "SA101 box N (Section name)"
  so users and the eventual filing worker are never ambiguous.

  Boxes NOT seeded, deliberately (all printed "not in use" on the
  form, or personal details):
    - Name and UTR header fields — already held on the user profile.
    - Share schemes section: box 2.
    - Other tax reliefs: box 11.
    - Pension Savings Tax Charges: boxes 7, 8, 9 and 17.

  Tax avoidance schemes (boxes 19 + 20) are one repeating_group
  question — the paper form prints THREE rows of (scheme reference
  number, expected-advantage tax year) pairs, so the group is capped
  at max_items = 3 with one subfield per box.

  Label fidelity: labels are the form's own wording; long dash
  clarifications live in help_text. Adapted wording (questions are
  shared across tax years, answer_scope='year'):
    - losses box 1 "…in 2025–26" → "…in this tax year"
    - losses box 3 "…for 2026–27 trade losses…" → "…for next year's
      trade losses…" (the paper form names the year AFTER the one
      being filed)
    - MCA box 5 "in the year to 5 April 2026" → "during this tax year"
    - MCA box 9 "after 5 April 2025" → "after the start of this tax
      year"
  Each adaptation is explained in that question's help_text.

  card_total = true marks the INCOME boxes only — the figures a
  "total other income" headline can honestly sum:
    gilt gross interest (box 3 — boxes 1+2 are the net/tax split of
    the same income, so only the gross is flagged to avoid double
    counting), life policy gains (4, 6, 8), stock dividends (12),
    bonus issues (13), close company loans written off (13.1),
    business receipts (14), and the employment section's income
    boxes (1, 3, 4, 5). Reliefs, deductions, tax-taken-off, MCA,
    losses, pension charges and avoidance-scheme details are NOT
    income and are excluded. Consumers: ContextSections' rail total
    (reads the flag) and FormSectionQueries.card_summary (hardcodes
    the same key list — see the comment there for why).

  No negative-allowed boxes: unlike SA108, SA101 prints no minus
  indicators — every monetary box gets {"min":0}.

  Answer scoping — one set of answers PER USER PER TAX YEAR
  (answer_scope='year', context='other'; the [type] page discovers
  the context automatically via the schema endpoint).

  Idempotent: keyed on category.slug + question.question_key; only
  ever INSERTs, never UPDATEs, so admin edits are always preserved.

  Only executed when PROJECT_CODE includes 'tax_copilot'.
]]

local db = require("lapis.db")
local cjson = require("cjson")
local MigrationUtils = require "helper.migration-utils"

-- Resolve the tax-copilot namespace ID by SLUG (ids are per-env
-- auto-increment). Falls back to 0 (global) if the namespace doesn't
-- exist yet — same rationale as the dividends/SA108 seeds.
local function taxCopilotNamespaceId()
    local ok, rows = pcall(db.query, [[
        SELECT id FROM namespaces
        WHERE slug = 'tax-copilot' AND status = 'active'
        LIMIT 1
    ]])
    if ok and rows and #rows > 0 then
        return tonumber(rows[1].id)
    end
    return 0
end

local TAX_YEAR_HELP = "Enter in YYYY-YY format, for example 2024-25."

-- The full SA101 catalogue. Category fields: slug, name, description,
-- order, section (hmrc_mapping section slug shared by its questions),
-- questions. Question fields: key, label, box, order, help,
-- qtype (default "currency"), card_total, validation (Lua table),
-- placeholder, group_config (repeating_group only).
local SEED = {
    {
        slug = "ai-gilt-interest",
        name = "Interest from gilt-edged and other UK securities, deeply "
            .. "discounted securities and accrued income profits",
        description = "SA101 page Ai 1, under ‘Other UK income’.",
        order = 10,
        section = "other_uk_income",
        questions = {
            {
                key = "sa101_gilt_interest_after_tax",
                label = "Gilt etc interest after tax taken off",
                box = "1", order = 10,
                help = "SA101 box 1 (Other UK income).",
                validation = { min = 0 },
            },
            {
                key = "sa101_gilt_tax_taken_off",
                label = "Tax taken off",
                box = "2", order = 20,
                help = "SA101 box 2 (Other UK income).",
                validation = { min = 0 },
            },
            {
                key = "sa101_gilt_gross_before_tax",
                label = "Gross amount before tax",
                box = "3", order = 30, card_total = true,
                help = "SA101 box 3 (Other UK income).",
                validation = { min = 0 },
            },
        },
    },
    {
        slug = "ai-life-insurance-gains",
        name = "Gains from life insurance policies, capital redemption "
            .. "policies and life annuity contracts",
        description = "SA101 page Ai 1, under ‘Other UK income’.",
        order = 20,
        section = "other_uk_income",
        questions = {
            {
                key = "sa101_lip_gains_tax_treated_paid",
                label = "UK policy or contract gains on which tax was treated "
                    .. "as paid – the amount of the gain",
                box = "4", order = 10, card_total = true,
                help = "SA101 box 4 (Other UK income).",
                validation = { min = 0 },
            },
            {
                key = "sa101_lip_years_tax_treated_paid",
                label = "Number of years the policy has been held or since "
                    .. "the last gain",
                box = "5", order = 20, qtype = "number",
                help = "Relates to the gain in box 4. SA101 box 5 "
                    .. "(Other UK income).",
                validation = { min = 0, integer = true },
            },
            {
                key = "sa101_lip_gains_no_tax_treated",
                label = "UK policy or contract gains where no tax was treated "
                    .. "as paid – the amount of the gain",
                box = "6", order = 30, card_total = true,
                help = "SA101 box 6 (Other UK income).",
                validation = { min = 0 },
            },
            {
                key = "sa101_lip_years_no_tax_treated",
                label = "Number of years the policy has been held or since "
                    .. "the last gain",
                box = "7", order = 40, qtype = "number",
                help = "Relates to the gain in box 6. SA101 box 7 "
                    .. "(Other UK income).",
                validation = { min = 0, integer = true },
            },
            {
                key = "sa101_lip_gains_voided_isas",
                label = "UK policy or contract gains from voided ISAs",
                box = "8", order = 50, card_total = true,
                help = "SA101 box 8 (Other UK income).",
                validation = { min = 0 },
            },
            {
                key = "sa101_lip_years_voided_isas",
                label = "Number of years the policy was held",
                box = "9", order = 60, qtype = "number",
                help = "Relates to the gain in box 8. SA101 box 9 "
                    .. "(Other UK income).",
                validation = { min = 0, integer = true },
            },
            {
                key = "sa101_lip_tax_taken_off_box8",
                label = "Tax taken off gain shown in box 8",
                box = "10", order = 70,
                help = "SA101 box 10 (Other UK income).",
                validation = { min = 0 },
            },
            {
                key = "sa101_lip_deficiency_relief",
                label = "Deficiency relief",
                box = "11", order = 80,
                help = "SA101 box 11 (Other UK income).",
                validation = { min = 0 },
            },
        },
    },
    {
        slug = "ai-stock-dividends",
        name = "Stock dividends, bonus issues of securities and "
            .. "redeemable shares",
        description = "SA101 page Ai 1, under ‘Other UK income’.",
        order = 30,
        section = "other_uk_income",
        questions = {
            {
                key = "sa101_sd_stock_dividends",
                label = "Stock dividends – the amount received",
                box = "12", order = 10, card_total = true,
                help = "SA101 box 12 (Other UK income).",
                validation = { min = 0 },
            },
            {
                key = "sa101_sd_bonus_issues",
                label = "Bonus issues of securities and redeemable shares",
                box = "13", order = 20, card_total = true,
                help = "SA101 box 13 (Other UK income).",
                validation = { min = 0 },
            },
            {
                key = "sa101_sd_close_company_loans",
                label = "Close company loans written off or released",
                box = "13.1", order = 30, card_total = true,
                help = "SA101 box 13.1 (Other UK income).",
                validation = { min = 0 },
            },
        },
    },
    {
        slug = "ai-business-receipts",
        name = "Business receipts taxed as income of an earlier year",
        description = "SA101 page Ai 1, under ‘Other UK income’.",
        order = 40,
        section = "other_uk_income",
        questions = {
            {
                key = "sa101_bri_amount",
                label = "The amount of post-cessation or other business receipts",
                box = "14", order = 10, card_total = true,
                help = "SA101 box 14 (Other UK income).",
                validation = { min = 0 },
            },
            {
                key = "sa101_bri_tax_year",
                label = "Tax year income to be taxed",
                box = "15", order = 20, qtype = "short_text",
                placeholder = "2024-25",
                help = TAX_YEAR_HELP .. " SA101 box 15 (Other UK income).",
                validation = { max_length = 7 },
            },
        },
    },
    {
        slug = "ai-employment-lump-sums",
        name = "Share schemes and employment lump sums, compensation and "
            .. "deductions, certain post-employment income and patent "
            .. "royalty payments",
        description = "SA101 page Ai 2. Box 2 is not in use on the form.",
        order = 50,
        section = "employment_lump_sums",
        questions = {
            {
                key = "sa101_emp_share_schemes",
                label = "Share schemes – the taxable amount",
                box = "1", order = 10, card_total = true,
                help = "Excluding amounts included on your P60 or P45. "
                    .. "SA101 box 1 (Share schemes and employment lump sums).",
                validation = { min = 0 },
            },
            -- Box 2 is printed "not in use" on the form — intentionally absent.
            {
                key = "sa101_emp_taxable_lump_sums",
                label = "Taxable lump sums and certain income after the end "
                    .. "of your job",
                box = "3", order = 20, card_total = true,
                help = "Excluding redundancy and compensation for loss of "
                    .. "your job. SA101 box 3 (Share schemes and employment "
                    .. "lump sums).",
                validation = { min = 0 },
            },
            {
                key = "sa101_emp_efrbs_lump_sums",
                label = "Lump sums or benefits received from an Employer "
                    .. "Financed Retirement Benefits Scheme excluding pensions",
                box = "4", order = 30, card_total = true,
                help = "SA101 box 4 (Share schemes and employment lump sums).",
                validation = { min = 0 },
            },
            {
                key = "sa101_emp_redundancy_above_30k",
                label = "Redundancy, other lump sums and compensation payments "
                    .. "– the amount above the £30,000 exemption",
                box = "5", order = 40, card_total = true,
                help = "SA101 box 5 (Share schemes and employment lump sums).",
                validation = { min = 0 },
            },
            {
                key = "sa101_emp_tax_taken_off",
                label = "Tax taken off boxes 3 to 5",
                box = "6", order = 50,
                help = "SA101 box 6 (Share schemes and employment lump sums).",
                validation = { min = 0 },
            },
            {
                key = "sa101_emp_tax_in_employment_page",
                label = "If you’ve left box 6 blank because the tax is "
                    .. "included in box 2 on the ‘Employment’ "
                    .. "page, put ‘X’ in the box",
                box = "7", order = 60, qtype = "boolean",
                help = "Answering Yes is the same as putting ‘X’ "
                    .. "in the box on the paper form. SA101 box 7 (Share "
                    .. "schemes and employment lump sums).",
            },
            {
                key = "sa101_emp_box4_exemptions",
                label = "Exemptions for amounts entered in box 4",
                box = "8", order = 70,
                help = "SA101 box 8 (Share schemes and employment lump sums).",
                validation = { min = 0 },
            },
            {
                key = "sa101_emp_comp_up_to_30k",
                label = "Compensation and lump sums up to £30,000 exemption",
                box = "9", order = 80,
                help = "SA101 box 9 (Share schemes and employment lump sums).",
                validation = { min = 0 },
            },
            {
                key = "sa101_emp_disability_foreign_service",
                label = "Disability and foreign service deduction",
                box = "10", order = 90,
                help = "SA101 box 10 (Share schemes and employment lump sums).",
                validation = { min = 0 },
            },
            {
                key = "sa101_emp_seafarers_deduction",
                label = "Seafarers’ Earnings Deduction",
                box = "11", order = 100,
                help = "Enter pay on your ‘Employment’ page "
                    .. "– read Helpsheet 205. SA101 box 11 (Share "
                    .. "schemes and employment lump sums).",
                validation = { min = 0 },
            },
            {
                key = "sa101_emp_foreign_earnings_not_taxable",
                label = "Foreign earnings not taxable in the UK",
                box = "12", order = 110,
                help = "SA101 box 12 (Share schemes and employment lump sums).",
                validation = { min = 0 },
            },
            {
                key = "sa101_emp_foreign_tax_no_credit",
                label = "Foreign tax for which tax credit relief not claimed",
                box = "13", order = 120,
                help = "SA101 box 13 (Share schemes and employment lump sums).",
                validation = { min = 0 },
            },
            {
                key = "sa101_emp_exempt_overseas_pension_contribs",
                label = "Exempt employers’ contributions to an overseas "
                    .. "pension scheme",
                box = "14", order = 130,
                help = "Read the notes. SA101 box 14 (Share schemes and "
                    .. "employment lump sums).",
                validation = { min = 0 },
            },
            {
                key = "sa101_emp_patent_royalties",
                label = "UK patent royalty payments made",
                box = "15", order = 140,
                help = "SA101 box 15 (Share schemes and employment lump sums).",
                validation = { min = 0 },
            },
        },
    },
    {
        slug = "ai-other-tax-reliefs",
        name = "Other tax reliefs",
        description = "SA101 page Ai 2 – read the notes. Box 11 is "
            .. "not in use on the form.",
        order = 60,
        section = "other_tax_reliefs",
        questions = {
            {
                key = "sa101_rel_vct",
                label = "Subscriptions for Venture Capital Trust shares "
                    .. "– the amount on which relief is claimed",
                box = "1", order = 10,
                help = "SA101 box 1 (Other tax reliefs).",
                validation = { min = 0 },
            },
            {
                key = "sa101_rel_eis",
                label = "Subscriptions for Enterprise Investment Scheme shares "
                    .. "– the amount on which relief is claimed",
                box = "2", order = 20,
                help = "SA101 box 2 (Other tax reliefs).",
                validation = { min = 0 },
            },
            {
                key = "sa101_rel_citr",
                label = "Community Investment Tax Relief – the amount "
                    .. "on which relief is claimed",
                box = "3", order = 30,
                help = "SA101 box 3 (Other tax reliefs).",
                validation = { min = 0 },
            },
            {
                key = "sa101_rel_annual_payments",
                label = "Annual payments made",
                box = "4", order = 40,
                help = "SA101 box 4 (Other tax reliefs).",
                validation = { min = 0 },
            },
            {
                key = "sa101_rel_qualifying_loan_interest",
                label = "Qualifying loan interest payable in the year",
                box = "5", order = 50,
                help = "SA101 box 5 (Other tax reliefs).",
                validation = { min = 0 },
            },
            {
                key = "sa101_rel_post_cessation_trade",
                label = "Post-cessation trade relief and certain other losses",
                box = "6", order = 60,
                help = "SA101 box 6 (Other tax reliefs).",
                validation = { min = 0 },
            },
            {
                key = "sa101_rel_pre_incorporation_losses",
                label = "Pre-incorporation losses",
                box = "6.1", order = 70,
                help = "SA101 box 6.1 (Other tax reliefs).",
                validation = { min = 0 },
            },
            {
                key = "sa101_rel_maintenance_payments",
                label = "Maintenance payments (up to £4,360)",
                box = "7", order = 80,
                help = "If you or your former spouse or civil partner were "
                    .. "born before 6 April 1935. SA101 box 7 (Other tax "
                    .. "reliefs).",
                validation = { min = 0 },
            },
            {
                key = "sa101_rel_trade_union_death_benefits",
                label = "Payments to a trade union for death benefits – "
                    .. "half the amount paid (maximum £100)",
                box = "8", order = 90,
                help = "SA101 box 8 (Other tax reliefs).",
                validation = { min = 0 },
            },
            {
                key = "sa101_rel_bonus_redemption_distribution",
                label = "Relief claimed on a qualifying distribution on the "
                    .. "redemption of bonus shares or securities",
                box = "9", order = 100,
                help = "SA101 box 9 (Other tax reliefs).",
                validation = { min = 0 },
            },
            {
                key = "sa101_rel_seis",
                label = "Subscriptions for shares under the Seed Enterprise "
                    .. "Investment Scheme",
                box = "10", order = 110,
                help = "SA101 box 10 (Other tax reliefs).",
                validation = { min = 0 },
            },
            -- Box 11 is printed "not in use" on the form — intentionally absent.
            {
                key = "sa101_rel_nondeductible_loan_interest",
                label = "Non-deductible loan interest from investments into "
                    .. "property letting partnerships",
                box = "12", order = 120,
                help = "SA101 box 12 (Other tax reliefs).",
                validation = { min = 0 },
            },
        },
    },
    {
        slug = "ai-married-couples-allowance",
        name = "Married Couple’s Allowance",
        description = "SA101 page Ai 3. Only complete if either you, your "
            .. "spouse or civil partner were born before 6 April 1935. If "
            .. "you were both born on or after 6 April 1935 and want to "
            .. "claim Marriage Allowance, use the Marriage Allowance section "
            .. "of the main return instead. Read the SA101 notes for who "
            .. "completes which boxes (higher-income partner: boxes 1 to 5 "
            .. "and 9; lower-income partner: boxes 6 to 11).",
        order = 70,
        section = "married_couples_allowance",
        questions = {
            {
                key = "sa101_mca_spouse_name",
                label = "Your spouse’s or civil partner’s full name",
                box = "1", order = 10, qtype = "short_text",
                help = "Complete if you’re the husband (marriages up "
                    .. "to 5 December 2005), or the spouse or civil partner "
                    .. "with the higher income (marriages and civil "
                    .. "partnerships on or after 5 December 2005). SA101 "
                    .. "box 1 (Married Couple’s Allowance).",
            },
            {
                key = "sa101_mca_spouse_dob",
                label = "Their date of birth if older than you (and at least "
                    .. "one of you was born before 6 April 1935)",
                box = "2", order = 20, qtype = "date",
                help = "SA101 box 2 (Married Couple’s Allowance).",
            },
            {
                key = "sa101_mca_half_allowance_to_spouse",
                label = "If you’ve already agreed that half the minimum "
                    .. "allowance is to go to your spouse or civil partner, "
                    .. "put ‘X’ in the box",
                box = "3", order = 30, qtype = "boolean",
                help = "Answering Yes is the same as putting ‘X’ "
                    .. "in the box on the paper form. SA101 box 3 (Married "
                    .. "Couple’s Allowance).",
            },
            {
                key = "sa101_mca_all_allowance_to_spouse",
                label = "If you’ve already agreed that all of the "
                    .. "minimum allowance is to go to your spouse or civil "
                    .. "partner, put ‘X’ in the box",
                box = "4", order = 40, qtype = "boolean",
                help = "Answering Yes is the same as putting ‘X’ "
                    .. "in the box on the paper form. SA101 box 4 (Married "
                    .. "Couple’s Allowance).",
            },
            {
                key = "sa101_mca_previous_partner_dob",
                label = "If, during this tax year, you lived with any previous "
                    .. "spouse or civil partner, enter their date of birth",
                box = "5", order = 50, qtype = "date",
                help = "On the paper form this box names the end of the tax "
                    .. "year being filed for (‘in the year to 5 "
                    .. "April…’). SA101 box 5 (Married "
                    .. "Couple’s Allowance).",
            },
            {
                key = "sa101_mca_half_allowance_to_you",
                label = "If you’ve already agreed that half of the "
                    .. "minimum allowance is to be given to you, put "
                    .. "‘X’ in the box",
                box = "6", order = 60, qtype = "boolean",
                help = "Answering Yes is the same as putting ‘X’ "
                    .. "in the box on the paper form. SA101 box 6 (Married "
                    .. "Couple’s Allowance).",
            },
            {
                key = "sa101_mca_all_allowance_to_you",
                label = "If you’ve already agreed that all of the "
                    .. "minimum allowance is to be given to you, put "
                    .. "‘X’ in the box",
                box = "7", order = 70, qtype = "boolean",
                help = "Answering Yes is the same as putting ‘X’ "
                    .. "in the box on the paper form. SA101 box 7 (Married "
                    .. "Couple’s Allowance).",
            },
            {
                key = "sa101_mca_spouse_name_lower_income",
                label = "Your spouse’s or civil partner’s full name",
                box = "8", order = 80, qtype = "short_text",
                help = "Complete if you’re the wife (marriages up to "
                    .. "5 December 2005), or the spouse or civil partner "
                    .. "with the lower income (marriages and civil "
                    .. "partnerships on or after 5 December 2005). SA101 "
                    .. "box 8 (Married Couple’s Allowance).",
            },
            {
                key = "sa101_mca_marriage_date",
                label = "If you were married or formed a civil partnership "
                    .. "after the start of this tax year, enter the date of "
                    .. "marriage or civil partnership",
                box = "9", order = 90, qtype = "date",
                help = "On the paper form this box names the start of the "
                    .. "tax year being filed for (‘after 5 "
                    .. "April…’). SA101 box 9 (Married "
                    .. "Couple’s Allowance).",
            },
            {
                key = "sa101_mca_receive_surplus",
                label = "If you want to have your spouse’s or civil "
                    .. "partner’s surplus allowance, put ‘X’ "
                    .. "in the box",
                box = "10", order = 100, qtype = "boolean",
                help = "Answering Yes is the same as putting ‘X’ "
                    .. "in the box on the paper form. SA101 box 10 (Married "
                    .. "Couple’s Allowance).",
            },
            {
                key = "sa101_mca_give_surplus",
                label = "If you want your spouse or civil partner to have "
                    .. "your surplus allowance, put ‘X’ in the box",
                box = "11", order = 110, qtype = "boolean",
                help = "Answering Yes is the same as putting ‘X’ "
                    .. "in the box on the paper form. SA101 box 11 (Married "
                    .. "Couple’s Allowance).",
            },
        },
    },
    {
        slug = "ai-income-tax-losses",
        name = "Income Tax losses and limit on Income Tax relief",
        description = "SA101 page Ai 3, under ‘Other information’. "
            .. "Boxes 1–2: other income losses. Boxes 3–5: trade "
            .. "losses from a later year. Box 6: limit on Income Tax relief.",
        order = 80,
        section = "income_tax_losses",
        questions = {
            {
                key = "sa101_loss_earlier_years",
                label = "Earlier years’ losses – which can be "
                    .. "set against certain other income in this tax year",
                box = "1", order = 10,
                help = "On the paper form this box names the tax year being "
                    .. "filed for. SA101 box 1 (Income Tax losses).",
                validation = { min = 0 },
            },
            {
                key = "sa101_loss_unused_carried_forward",
                label = "Total unused losses carried forward",
                box = "2", order = 20,
                help = "SA101 box 2 (Income Tax losses).",
                validation = { min = 0 },
            },
            {
                key = "sa101_loss_later_year_relief",
                label = "Relief now for next year’s trade losses or "
                    .. "certain capital losses",
                box = "3", order = 30,
                help = "Read the notes. On the paper form this box names the "
                    .. "tax year AFTER the one being filed for. SA101 box 3 "
                    .. "(Income Tax losses).",
                validation = { min = 0 },
            },
            {
                key = "sa101_loss_relief_not_limited",
                label = "Enter the amount of relief shown in box 3 which is "
                    .. "not subject to the limit on Income Tax reliefs",
                box = "4", order = 40,
                help = "SA101 box 4 (Income Tax losses).",
                validation = { min = 0 },
            },
            {
                key = "sa101_loss_relief_tax_year",
                label = "Tax year for which you’re claiming relief in box 3",
                box = "5", order = 50, qtype = "short_text",
                placeholder = "2024-25",
                help = TAX_YEAR_HELP .. " SA101 box 5 (Income Tax losses).",
                validation = { max_length = 7 },
            },
            {
                key = "sa101_loss_payroll_giving",
                label = "Amount of payroll giving",
                box = "6", order = 60,
                help = "Limit on Income Tax relief. SA101 box 6 (Income Tax "
                    .. "losses).",
                validation = { min = 0 },
            },
        },
    },
    {
        slug = "ai-pension-savings-charges",
        name = "Pension Savings Tax Charges",
        description = "SA101 page Ai 4. Boxes 7, 8, 9 and 17 are not in use "
            .. "on the form.",
        order = 90,
        section = "pension_savings_tax_charges",
        questions = {
            -- Boxes 7, 8 and 9 are printed "not in use" — intentionally absent.
            {
                key = "sa101_pstc_excess_annual_allowance",
                label = "Amount saved towards your pension, in the period "
                    .. "covered by this tax return, in excess of the "
                    .. "Annual Allowance",
                box = "10", order = 10,
                help = "SA101 box 10 (Pension Savings Tax Charges).",
                validation = { min = 0 },
            },
            {
                key = "sa101_pstc_annual_allowance_tax",
                label = "Annual Allowance tax paid or payable by your "
                    .. "pension scheme",
                box = "11", order = 20,
                help = "SA101 box 11 (Pension Savings Tax Charges).",
                validation = { min = 0 },
            },
            {
                key = "sa101_pstc_overseas_transfer_value",
                label = "Value of pension benefits transferred subject to "
                    .. "the overseas transfer charge",
                box = "11.1", order = 30,
                help = "SA101 box 11.1 (Pension Savings Tax Charges).",
                validation = { min = 0 },
            },
            {
                key = "sa101_pstc_overseas_transfer_tax",
                label = "Tax paid by your pension scheme on your overseas "
                    .. "transfer charge",
                box = "11.2", order = 40,
                help = "SA101 box 11.2 (Pension Savings Tax Charges).",
                validation = { min = 0 },
            },
            {
                key = "sa101_pstc_pstr",
                label = "Pension scheme tax reference number",
                box = "12", order = 50, qtype = "short_text",
                placeholder = "12345678RA",
                help = "The paper form prints the PSTR prefix before the "
                    .. "boxes. SA101 box 12 (Pension Savings Tax Charges).",
                validation = { max_length = 10 },
            },
            {
                key = "sa101_pstc_unauthorised_no_surcharge",
                label = "Amount of unauthorised payment from a pension "
                    .. "scheme, not subject to surcharge",
                box = "13", order = 60,
                help = "SA101 box 13 (Pension Savings Tax Charges).",
                validation = { min = 0 },
            },
            {
                key = "sa101_pstc_unauthorised_surcharge",
                label = "Amount of unauthorised payment from a pension "
                    .. "scheme, subject to surcharge",
                box = "14", order = 70,
                help = "SA101 box 14 (Pension Savings Tax Charges).",
                validation = { min = 0 },
            },
            {
                key = "sa101_pstc_foreign_tax_unauthorised",
                label = "Foreign tax paid on an unauthorised payment "
                    .. "(in £ sterling)",
                box = "15", order = 80,
                help = "SA101 box 15 (Pension Savings Tax Charges).",
                validation = { min = 0 },
            },
            {
                key = "sa101_pstc_short_service_refund",
                label = "Taxable short service refund of contributions "
                    .. "(overseas pension schemes only)",
                box = "16", order = 90,
                help = "SA101 box 16 (Pension Savings Tax Charges).",
                validation = { min = 0 },
            },
            -- Box 17 is printed "not in use" — intentionally absent.
            {
                key = "sa101_pstc_foreign_tax_short_service",
                label = "Foreign tax paid (in £ sterling) on box 16",
                box = "18", order = 100,
                help = "SA101 box 18 (Pension Savings Tax Charges).",
                validation = { min = 0 },
            },
        },
    },
    {
        slug = "ai-tax-avoidance-schemes",
        name = "Tax avoidance schemes",
        description = "SA101 page Ai 4.",
        order = 100,
        section = "tax_avoidance_schemes",
        questions = {
            {
                key = "sa101_tas_schemes",
                label = "The scheme reference number or promoter reference "
                    .. "number, and the tax year in which the expected "
                    .. "advantage arises",
                box = "19,20", order = 10, qtype = "repeating_group",
                help = "One row per scheme – the paper form has room "
                    .. "for 3. SA101 boxes 19 and 20 (Tax avoidance schemes).",
                group_config = {
                    fields = {
                        {
                            key = "scheme_ref",
                            label = "Scheme reference number or promoter reference number",
                            type = "short_text",
                            required = true,
                        },
                        {
                            key = "expected_advantage_year",
                            label = "Tax year in which the expected advantage arises",
                            type = "short_text",
                            placeholder = "2024-25",
                            help = TAX_YEAR_HELP,
                        },
                    },
                    item_label = "Scheme",
                    add_button_label = "Add scheme",
                    min_items = 0,
                    max_items = 3,
                },
            },
        },
    },
}

-- Encode config_json for one question. Every question carries its
-- SA101 mapping with the SECTION slug — SA101 box numbers restart per
-- section group, so form+box alone is ambiguous. Currency questions
-- carry the same UI input hint as the dividends/SA108 seeds; the
-- income boxes carry card_total = true (see file header). For the
-- repeating_group question the widget's field schema and the
-- hmrc_mapping share the same config object (the widget ignores
-- unknown keys).
local function config_json_for(cat, q)
    local cfg = q.group_config or {}
    cfg.hmrc_mapping = { form = "SA101", section = cat.section, box = q.box }
    if (q.qtype or "currency") == "currency" then
        cfg.input = { currency = "GBP", scale = 2 }
    end
    if q.card_total then
        cfg.card_total = true
    end
    return cjson.encode(cfg)
end

-- Encode validation_json, or db.NULL when the question has none.
-- db.NULL — never nil — because Lua truncates varargs at the first nil.
local function validation_json_for(q)
    if q.validation then
        return cjson.encode(q.validation)
    end
    return db.NULL
end

return {
    -- =========================================================================
    -- 1. Seed the ten SA101 categories (one per boxed section group).
    --    Idempotent on slug; admin can rename freely via the admin UI.
    --    context='other' — the income_types key the /my-income/[type]
    --    auto-discovery convention requires — with answer_scope='year'
    --    and the tax-copilot namespace resolved by slug.
    -- =========================================================================
    [1] = function()
        local ns_id = taxCopilotNamespaceId()
        local created = 0
        for _, cat in ipairs(SEED) do
            local existing = db.select(
                "id FROM profile_categories WHERE slug = ? LIMIT 1", cat.slug
            )
            if #existing == 0 then
                db.query([[
                    INSERT INTO profile_categories
                        (uuid, namespace_id, name, slug, description, icon,
                         display_order, is_active, is_archived, context,
                         answer_scope, created_at, updated_at)
                    VALUES (?, ?, ?, ?, ?, ?, ?, TRUE, FALSE, 'other',
                            'year', NOW(), NOW())
                ]],
                    MigrationUtils.generateUUID(),
                    ns_id,
                    cat.name,
                    cat.slug,
                    cat.description,
                    "pound-sign",
                    cat.order
                )
                created = created + 1
            end
        end
        print(string.format(
            "[SA101 Additional information] Seeded %d/%d profile categories (context='other')",
            created, #SEED
        ))
    end,

    -- =========================================================================
    -- 2. Seed the SA101 questions under their categories.
    --    Idempotent on question_key; only ever INSERTs so admin edits
    --    to seeded questions are preserved.
    -- =========================================================================
    [2] = function()
        local ns_id = taxCopilotNamespaceId()
        local created, total = 0, 0
        for _, cat in ipairs(SEED) do
            local rows = db.select(
                "id FROM profile_categories WHERE slug = ? LIMIT 1", cat.slug
            )
            if #rows == 0 then
                -- Category seed failed / was rolled back — skip rather
                -- than orphan questions.
                print("[SA101 Additional information] Category missing, skipping: " .. cat.slug)
            else
                local category_id = rows[1].id
                for _, q in ipairs(cat.questions) do
                    total = total + 1
                    local existing = db.select(
                        "id FROM profile_questions WHERE question_key = ? LIMIT 1",
                        q.key
                    )
                    if #existing == 0 then
                        db.query([[
                            INSERT INTO profile_questions
                                (uuid, namespace_id, category_id, question_key,
                                 label, help_text, placeholder, question_type,
                                 is_required, is_multi_value,
                                 is_editable_by_user, display_order,
                                 config_json, validation_json, is_active,
                                 is_archived, created_at, updated_at)
                            VALUES (?, ?, ?, ?, ?, ?, ?, ?, FALSE, FALSE,
                                    TRUE, ?, ?, ?, TRUE, FALSE, NOW(), NOW())
                        ]],
                            MigrationUtils.generateUUID(),
                            ns_id,
                            category_id,
                            q.key,
                            q.label,
                            q.help,
                            q.placeholder or db.NULL,
                            q.qtype or "currency",
                            q.order,
                            config_json_for(cat, q),
                            validation_json_for(q)
                        )
                        created = created + 1
                    end
                end
            end
        end
        print(string.format(
            "[SA101 Additional information] Seeded %d/%d SA101 questions",
            created, total
        ))
    end,

    -- =========================================================================
    -- 3. Linked-form metadata defaults for the income types migration
    --    771 (income-types-linked-form-metadata) missed:
    --      - 'other' — SA101, the panel this file seeds; didn't exist
    --        when 771 shipped.
    --      - 'capital_gains' — 771 seeded its row under the key
    --        'sa108', which matches no income_types row (the catalogue
    --        key is 'capital_gains'), so the UPDATE silently no-oped
    --        and the CGT panel never got its reference-form card.
    --    Same COALESCE non-clobber contract as 771. A NEW step rather
    --    than an edit to 771's list because 771 is already tracked as
    --    run in envs and would never re-execute (the dividends-750a
    --    self-heal precedent). Weblinks point at the stable gov.uk
    --    publication pages rather than assets.publishing hash URLs —
    --    the hashes change with every form revision.
    -- =========================================================================
    [3] = function()
        local seeds = {
            {
                key = "other",
                title = "SA101",
                description = "These fields map directly to the SA101 Additional information form.",
                weblink = "https://www.gov.uk/government/publications/self-assessment-additional-information-sa101",
            },
            {
                key = "capital_gains",
                title = "SA108",
                description = "These fields map directly to the SA108 Capital Gains Tax summary form.",
                weblink = "https://www.gov.uk/government/publications/self-assessment-capital-gains-summary-sa108",
            },
        }
        for _, s in ipairs(seeds) do
            db.query([[
                UPDATE income_types
                   SET linked_form_title       = COALESCE(linked_form_title, ?),
                       linked_form_description = COALESCE(linked_form_description, ?),
                       linked_form_weblink     = COALESCE(linked_form_weblink, ?),
                       updated_at              = NOW()
                 WHERE income_type_key = ?
            ]], s.title, s.description, s.weblink, s.key)
        end
        print("[SA101 Additional information] Seeded linked-form defaults for 'other' and 'capital_gains' (COALESCE — never overwrites admin edits)")
    end,
}
