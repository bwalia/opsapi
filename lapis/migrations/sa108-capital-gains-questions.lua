--[[
  SA108 Capital Gains Tax summary — every box on the SA108 (pages CG1
  to CG4) wired through the Dynamic Profile Builder so admins can
  rename, reorder, disable, add rules, or add entirely new boxes
  WITHOUT a code deploy. Mirrors the SA100 dividends seed
  (sa100-dividend-questions.lua), the reference pattern for a
  year-scoped HMRC form section.

  Source of truth: the SA108 2026 paper form ("Tax year 6 April 2025
  to 5 April 2026 (2025–26)", HMRC 12/25). One profile category per
  form section, in form order:

    CG1  Residential property and carried interest   boxes 3–13C
    CG1  Cryptoassets                                 boxes 13.1–13.8
    CG2  Other property, assets and gains             boxes 14–22 + 17.0–17.4
    CG2  Listed shares and securities                 boxes 23–30 + 26.1
    CG3  Unlisted shares and securities               boxes 31–44 + 34.1
    CG3  Losses and adjustments                       boxes 45–50.1
    CG4  Tax adjustments to capital gains             boxes 51–52
    CG4  Non-resident Capital Gains Tax (NRCGT)       boxes 52.1–52.5
    CG4  Excluded indexed securities and QAHC         boxes 52EG–52QL
    CG4  Any other information                        boxes 53–54

  Boxes NOT seeded, deliberately:
    - Box 1 (name) and box 2 (UTR) — personal details, already held on
      the user profile; the filing worker fills them from there.
    - Box 18 — printed "Box 18 is not in use" on the form.

  Label fidelity: labels are the form's own wording; the dash
  clarifications ("– any losses included in box …") live in help_text
  (rendered behind the HelpDisclosure). The only wording adapted is
  the four hardcoded tax years in boxes 41–44/46 ("2025–26 income")
  — questions are shared across tax years (answer_scope='year'), so
  those labels say "this tax year" / "the previous tax year" instead
  and help_text explains the mapping.

  config_json per question:
    - hmrc_mapping = {form="SA108", box="<n>"} — box refs are strings
      because SA108 numbering includes "6.1", "13A", "52EG.1".
    - input = {currency="GBP", scale=2} on currency boxes (same UI
      hint as the dividends seed).
    - card_total = true on the six "gains in the year, before losses"
      boxes (6, 13B, 13.4, 17, 26, 34). Consumers (the /my-income
      card aggregate and the panel rail) sum ONLY these for the
      headline figure — summing every box would add proceeds, costs
      and losses together into a meaningless number. The six are
      disjoint by construction: box 6 excludes carried interest
      (13B), and each covers a different asset class.

  Negative-allowed boxes (9, 11, 13.7, 21, 29, 37, 51 — the form
  prints a minus indicator on these): seeded WITHOUT a {"min":0}
  validation and with help_text telling the user to enter a loss as
  a negative number. Every other monetary box gets {"min":0}.

  Answer scoping — one set of answers PER USER PER TAX YEAR
  (answer_scope='year', same mechanism as dividends; the partial
  unique index idx_upa_user_question_year guarantees uniqueness).

  Idempotent: keyed on category.slug + question.question_key; only
  ever INSERTs, never UPDATEs, so admin edits to seeded rows are
  always preserved.

  Only executed when PROJECT_CODE includes 'tax_copilot'.
]]

local db = require("lapis.db")
local cjson = require("cjson")
local MigrationUtils = require "helper.migration-utils"

-- Resolve the tax-copilot namespace ID by SLUG (ids are per-env
-- auto-increment). Falls back to 0 (global) if the namespace doesn't
-- exist yet — same rationale as the dividends seed.
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

-- Shared help fragments, kept identical everywhere they recur on the
-- form so admins see the same wording the form repeats.
local FIG_HELP = "Amount claimed under the foreign income and gains (FIG) regime."
local CODE_HELP = "See the SA108 notes for the list of claim and election codes. "
    .. "Use 3 characters, for example PRR."
local LOSS_NEGATIVE_HELP = "If the total is an overall loss, enter it as a negative number."

-- The full SA108 catalogue: one entry per form section (= one
-- profile_categories row), each with its boxes in form order.
-- Question fields: key, label, box, order, help (optional),
-- qtype (default "currency"), negative (allow < 0), card_total,
-- validation (Lua table, encoded to validation_json).
local SEED = {
    {
        slug = "cg-residential-property-and-carried-interest",
        name = "Residential property and carried interest",
        description = "SA108 page CG1. You must enclose your computations, "
            .. "including details of each gain or loss, as well as filling in the boxes.",
        order = 10,
        questions = {
            {
                key = "sa108_res_num_disposals",
                label = "Number of disposals",
                box = "3", order = 10, qtype = "number",
                help = "How many residential property or carried interest disposals "
                    .. "you made in the year. SA108 box 3.",
                validation = { min = 0, integer = true },
            },
            {
                key = "sa108_res_disposal_proceeds",
                label = "Disposal proceeds",
                box = "4", order = 20,
                help = "SA108 box 4.",
                validation = { min = 0 },
            },
            {
                key = "sa108_res_allowable_costs",
                label = "Allowable costs (including purchase price)",
                box = "5", order = 30,
                help = "SA108 box 5.",
                validation = { min = 0 },
            },
            {
                key = "sa108_res_gains_before_losses",
                label = "Gains on residential property in the year, before losses",
                box = "6", order = 40, card_total = true,
                help = "Do not include gains on carried interest. Any gains on "
                    .. "residential property included in boxes 9 and 11 amounts "
                    .. "must be included in this total. SA108 box 6.",
                validation = { min = 0 },
            },
            {
                key = "sa108_res_fig_claim",
                label = "Amount claimed under the foreign income and gains (FIG) regime",
                box = "6.1", order = 50,
                help = FIG_HELP .. " Relates to the residential property gains "
                    .. "in box 6. SA108 box 6.1.",
                validation = { min = 0 },
            },
            {
                key = "sa108_res_losses_in_year",
                label = "Losses in the year",
                box = "7", order = 60,
                help = "Any losses included in boxes 9 and 11 amounts must be "
                    .. "included in this total. SA108 box 7.",
                validation = { min = 0 },
            },
            {
                key = "sa108_res_claim_election_code",
                label = "If you’re making any claim or election, put the relevant code in the box",
                box = "8", order = 70, qtype = "short_text",
                help = CODE_HELP .. " SA108 box 8.",
                validation = { max_length = 3 },
            },
            {
                key = "sa108_res_uk_ppd_gains_losses",
                label = "Total gains or losses on UK residential property reported "
                    .. "on Capital Gains Tax UK Property Disposal returns",
                box = "9", order = 80, negative = true,
                help = LOSS_NEGATIVE_HELP .. " SA108 box 9.",
            },
            {
                key = "sa108_res_uk_ppd_tax_charged",
                label = "Tax on gains in box 9 already charged",
                box = "10", order = 90,
                help = "SA108 box 10.",
                validation = { min = 0 },
            },
            {
                key = "sa108_res_rtt_gains_losses",
                label = "Total gains or losses on non-UK residential property or "
                    .. "carried interest reported on Real Time Transaction returns",
                box = "11", order = 100, negative = true,
                help = LOSS_NEGATIVE_HELP .. " SA108 box 11.",
            },
            {
                key = "sa108_res_rtt_tax_paid",
                label = "Tax on gains in box 11 already paid",
                box = "12", order = 110,
                help = "SA108 box 12.",
                validation = { min = 0 },
            },
            {
                key = "sa108_ci_arising",
                label = "Carried interest (arising basis) – the amount before any claim or election",
                box = "13", order = 120,
                help = "SA108 box 13.",
                validation = { min = 0 },
            },
            {
                key = "sa108_ci_accruals",
                label = "Carried interest (accruals basis) – the amount before any claim or election",
                box = "13A", order = 130,
                help = "SA108 box 13A.",
                validation = { min = 0 },
            },
            {
                key = "sa108_ci_gains_in_year",
                label = "Gains on carried interest in the year",
                box = "13B", order = 140, card_total = true,
                help = "The sum of boxes 13 and 13A, less any claim or election. "
                    .. "Any gains on carried interest included in box 11 amounts "
                    .. "must be included in this total. SA108 box 13B.",
                validation = { min = 0 },
            },
            {
                key = "sa108_ci_fig_claim",
                label = "Amount claimed under the foreign income and gains (FIG) regime",
                box = "13C", order = 150,
                help = FIG_HELP .. " Relates to the carried interest gains in "
                    .. "box 13B. SA108 box 13C.",
                validation = { min = 0 },
            },
        },
    },
    {
        slug = "cg-cryptoassets",
        name = "Cryptoassets",
        description = "SA108 page CG1. Disposals of cryptoassets, for example "
            .. "exchange tokens such as bitcoin.",
        order = 20,
        questions = {
            {
                key = "sa108_crypto_num_disposals",
                label = "Number of disposals",
                box = "13.1", order = 10, qtype = "number",
                help = "SA108 box 13.1.",
                validation = { min = 0, integer = true },
            },
            {
                key = "sa108_crypto_disposal_proceeds",
                label = "Disposal proceeds",
                box = "13.2", order = 20,
                help = "SA108 box 13.2.",
                validation = { min = 0 },
            },
            {
                key = "sa108_crypto_allowable_costs",
                label = "Allowable costs (including purchase price)",
                box = "13.3", order = 30,
                help = "SA108 box 13.3.",
                validation = { min = 0 },
            },
            {
                key = "sa108_crypto_gains_before_losses",
                label = "Gains in the year, before losses",
                box = "13.4", order = 40, card_total = true,
                help = "Any gains included in box 13.7 amounts must be included "
                    .. "in this total. SA108 box 13.4.",
                validation = { min = 0 },
            },
            {
                key = "sa108_crypto_losses_in_year",
                label = "Losses in the year",
                box = "13.5", order = 50,
                help = "Any losses included in box 13.7 amounts must be included "
                    .. "in this total. SA108 box 13.5.",
                validation = { min = 0 },
            },
            {
                key = "sa108_crypto_claim_election_code",
                label = "If you’re making any claim or election, put the relevant code in the box",
                box = "13.6", order = 60, qtype = "short_text",
                help = CODE_HELP .. " SA108 box 13.6.",
                validation = { max_length = 3 },
            },
            {
                key = "sa108_crypto_rtt_gains_losses",
                label = "Total gains or losses on the disposal of an asset of this "
                    .. "type reported on Real Time Transaction returns",
                box = "13.7", order = 70, negative = true,
                help = LOSS_NEGATIVE_HELP .. " SA108 box 13.7.",
            },
            {
                key = "sa108_crypto_rtt_tax_paid",
                label = "Tax on gains in box 13.7 already paid",
                box = "13.8", order = 80,
                help = "SA108 box 13.8.",
                validation = { min = 0 },
            },
        },
    },
    {
        slug = "cg-other-property-assets-and-gains",
        name = "Other property, assets and gains",
        description = "SA108 page CG2. Gains where Business Asset Disposal Relief "
            .. "(BADR) is being claimed should be included in this section.",
        order = 30,
        questions = {
            {
                key = "sa108_other_num_disposals",
                label = "Number of disposals",
                box = "14", order = 10, qtype = "number",
                help = "SA108 box 14.",
                validation = { min = 0, integer = true },
            },
            {
                key = "sa108_other_disposal_proceeds",
                label = "Disposal proceeds",
                box = "15", order = 20,
                help = "SA108 box 15.",
                validation = { min = 0 },
            },
            {
                key = "sa108_other_allowable_costs",
                label = "Allowable costs (including purchase price)",
                box = "16", order = 30,
                help = "SA108 box 16.",
                validation = { min = 0 },
            },
            {
                key = "sa108_other_gains_before_losses",
                label = "Gains in the year, before losses",
                box = "17", order = 40, card_total = true,
                help = "Any gains included in box 21 amounts must be included in "
                    .. "this total. SA108 box 17.",
                validation = { min = 0 },
            },
            {
                key = "sa108_other_fig_claim",
                label = "Amount claimed under the foreign income and gains (FIG) regime",
                box = "17.0", order = 50,
                help = FIG_HELP .. " SA108 box 17.0.",
                validation = { min = 0 },
            },
            {
                key = "sa108_other_nonres_land_amount",
                label = "Enter the amount included in box 17 total relating to "
                    .. "disposals of non-residential land and buildings",
                box = "17.1", order = 60,
                help = "SA108 box 17.1.",
                validation = { min = 0 },
            },
            {
                key = "sa108_other_badr_property",
                label = "Residential property and non-residential land and buildings",
                box = "17.2", order = 70,
                help = "In boxes 17.2 to 17.4, enter the amounts in the box 17 "
                    .. "total that relate to a disposal where BADR is being "
                    .. "claimed, as advised in the guidance notes. SA108 box 17.2.",
                validation = { min = 0 },
            },
            {
                key = "sa108_other_badr_shares",
                label = "Listed and unlisted shares and securities",
                box = "17.3", order = 80,
                help = "In boxes 17.2 to 17.4, enter the amounts in the box 17 "
                    .. "total that relate to a disposal where BADR is being "
                    .. "claimed, as advised in the guidance notes. SA108 box 17.3.",
                validation = { min = 0 },
            },
            {
                key = "sa108_other_badr_other_assets",
                label = "Other assets",
                box = "17.4", order = 90,
                help = "In boxes 17.2 to 17.4, enter the amounts in the box 17 "
                    .. "total that relate to a disposal where BADR is being "
                    .. "claimed, as advised in the guidance notes. SA108 box 17.4.",
                validation = { min = 0 },
            },
            -- Box 18 is printed "not in use" on the form — intentionally absent.
            {
                key = "sa108_other_losses_in_year",
                label = "Losses in the year",
                box = "19", order = 100,
                help = "Any losses included in box 21 amounts must be included in "
                    .. "this total. SA108 box 19.",
                validation = { min = 0 },
            },
            {
                key = "sa108_other_claim_election_code",
                label = "If you’re making any claim or election, put the relevant code in the box",
                box = "20", order = 110, qtype = "short_text",
                help = CODE_HELP .. " SA108 box 20.",
                validation = { max_length = 3 },
            },
            {
                key = "sa108_other_rtt_gains_losses",
                label = "Total gains or losses on the disposal of an asset of this "
                    .. "type reported on Real Time Transaction returns",
                box = "21", order = 120, negative = true,
                help = LOSS_NEGATIVE_HELP .. " SA108 box 21.",
            },
            {
                key = "sa108_other_rtt_tax_paid",
                label = "Tax on gains in box 21 already paid",
                box = "22", order = 130,
                help = "SA108 box 22.",
                validation = { min = 0 },
            },
        },
    },
    {
        slug = "cg-listed-shares-and-securities",
        name = "Listed shares and securities",
        description = "SA108 page CG2. Disposals of shares and securities listed "
            .. "on a recognised stock exchange.",
        order = 40,
        questions = {
            {
                key = "sa108_listed_num_disposals",
                label = "Number of disposals",
                box = "23", order = 10, qtype = "number",
                help = "SA108 box 23.",
                validation = { min = 0, integer = true },
            },
            {
                key = "sa108_listed_disposal_proceeds",
                label = "Disposal proceeds",
                box = "24", order = 20,
                help = "SA108 box 24.",
                validation = { min = 0 },
            },
            {
                key = "sa108_listed_allowable_costs",
                label = "Allowable costs (including purchase price)",
                box = "25", order = 30,
                help = "SA108 box 25.",
                validation = { min = 0 },
            },
            {
                key = "sa108_listed_gains_before_losses",
                label = "Gains in the year, before losses",
                box = "26", order = 40, card_total = true,
                help = "Any gains included in box 29 amounts must be included in "
                    .. "this total. SA108 box 26.",
                validation = { min = 0 },
            },
            {
                key = "sa108_listed_fig_claim",
                label = "Amount claimed under the foreign income and gains (FIG) regime",
                box = "26.1", order = 50,
                help = FIG_HELP .. " SA108 box 26.1.",
                validation = { min = 0 },
            },
            {
                key = "sa108_listed_losses_in_year",
                label = "Losses in the year",
                box = "27", order = 60,
                help = "Any losses included in box 29 amounts must be included in "
                    .. "this total. SA108 box 27.",
                validation = { min = 0 },
            },
            {
                key = "sa108_listed_claim_election_code",
                label = "If you’re making any claim or election, put the relevant code in the box",
                box = "28", order = 70, qtype = "short_text",
                help = CODE_HELP .. " SA108 box 28.",
                validation = { max_length = 3 },
            },
            {
                key = "sa108_listed_rtt_gains_losses",
                label = "Total gains or losses on the disposal of an asset of this "
                    .. "type reported on Real Time Transaction returns",
                box = "29", order = 80, negative = true,
                help = LOSS_NEGATIVE_HELP .. " SA108 box 29.",
            },
            {
                key = "sa108_listed_rtt_tax_paid",
                label = "Tax on gains in box 29 already paid",
                box = "30", order = 90,
                help = "SA108 box 30.",
                validation = { min = 0 },
            },
        },
    },
    {
        slug = "cg-unlisted-shares-and-securities",
        name = "Unlisted shares and securities",
        description = "SA108 page CG3. Disposals of shares and securities that "
            .. "are not listed on a recognised stock exchange.",
        order = 50,
        questions = {
            {
                key = "sa108_unlisted_num_disposals",
                label = "Number of disposals",
                box = "31", order = 10, qtype = "number",
                help = "SA108 box 31.",
                validation = { min = 0, integer = true },
            },
            {
                key = "sa108_unlisted_disposal_proceeds",
                label = "Disposal proceeds",
                box = "32", order = 20,
                help = "SA108 box 32.",
                validation = { min = 0 },
            },
            {
                key = "sa108_unlisted_allowable_costs",
                label = "Allowable costs (including purchase price)",
                box = "33", order = 30,
                help = "SA108 box 33.",
                validation = { min = 0 },
            },
            {
                key = "sa108_unlisted_gains_before_losses",
                label = "Gains in the year, before losses",
                box = "34", order = 40, card_total = true,
                help = "Any gains included in box 37 amounts must be included in "
                    .. "this total. SA108 box 34.",
                validation = { min = 0 },
            },
            {
                key = "sa108_unlisted_fig_claim",
                label = "Amount claimed under the foreign income and gains (FIG) regime",
                box = "34.1", order = 50,
                help = FIG_HELP .. " SA108 box 34.1.",
                validation = { min = 0 },
            },
            {
                key = "sa108_unlisted_losses_in_year",
                label = "Losses in the year",
                box = "35", order = 60,
                help = "Any losses included in box 37 amounts must be included in "
                    .. "this total. SA108 box 35.",
                validation = { min = 0 },
            },
            {
                key = "sa108_unlisted_claim_election_code",
                label = "If you’re making any claim or election, put the relevant code in the box",
                box = "36", order = 70, qtype = "short_text",
                help = CODE_HELP .. " SA108 box 36.",
                validation = { max_length = 3 },
            },
            {
                key = "sa108_unlisted_rtt_gains_losses",
                label = "Total gains or losses on the disposal of an asset of this "
                    .. "type reported on Real Time Transaction returns",
                box = "37", order = 80, negative = true,
                help = LOSS_NEGATIVE_HELP .. " SA108 box 37.",
            },
            {
                key = "sa108_unlisted_rtt_tax_paid",
                label = "Tax on gains in box 37 already paid",
                box = "38", order = 90,
                help = "SA108 box 38.",
                validation = { min = 0 },
            },
            {
                key = "sa108_ess_lifetime_excess_gains",
                label = "Gains exceeding the lifetime limit for employee "
                    .. "shareholder status shares",
                box = "39", order = 100,
                help = "SA108 box 39.",
                validation = { min = 0 },
            },
            {
                key = "sa108_seis_invested_gains",
                label = "Gains invested under Seed Enterprise Investment Scheme "
                    .. "and qualifying for relief",
                box = "40", order = 110,
                help = "SA108 box 40.",
                validation = { min = 0 },
            },
            {
                key = "sa108_losses_vs_income_current",
                label = "Losses used against income – amount claimed "
                    .. "against this tax year’s income",
                box = "41", order = 120,
                help = "The amount claimed against income of the tax year you "
                    .. "are filing for (the year selected above). On the paper "
                    .. "form this box names that year. SA108 box 41.",
                validation = { min = 0 },
            },
            {
                key = "sa108_losses_vs_income_current_eis_seis",
                label = "Amount in box 41 relating to share loss relief in this "
                    .. "tax year to which Enterprise Investment Scheme or Seed "
                    .. "Enterprise Investment Scheme Relief is attributable",
                box = "42", order = 130,
                help = "SA108 box 42.",
                validation = { min = 0 },
            },
            {
                key = "sa108_losses_vs_income_prior",
                label = "Losses used against income – amount claimed "
                    .. "against the previous tax year’s income",
                box = "43", order = 140,
                help = "The amount claimed against income of the tax year before "
                    .. "the one you are filing for. On the paper form this box "
                    .. "names that year. SA108 box 43.",
                validation = { min = 0 },
            },
            {
                key = "sa108_losses_vs_income_prior_eis_seis",
                label = "Amount in box 43 relating to share loss relief in the "
                    .. "previous tax year to which Enterprise Investment Scheme "
                    .. "or Seed Enterprise Investment Scheme Relief is attributable",
                box = "44", order = 150,
                help = "SA108 box 44.",
                validation = { min = 0 },
            },
        },
    },
    {
        slug = "cg-losses-and-adjustments",
        name = "Losses and adjustments",
        description = "SA108 page CG3. Losses set against this year’s "
            .. "capital gains, other loss information, and Investors’ "
            .. "Relief and Business Asset Disposal Relief (previously "
            .. "‘Entrepreneurs’ Relief’).",
        order = 60,
        questions = {
            {
                key = "sa108_losses_broughtfwd_used",
                label = "Losses brought forward and used in-year",
                box = "45", order = 10,
                help = "Losses set against this tax year’s capital gains. "
                    .. "SA108 box 45.",
                validation = { min = 0 },
            },
            {
                key = "sa108_income_losses_set_against_gains",
                label = "Income losses of this tax year set against gains",
                box = "46", order = 20,
                help = "On the paper form this box names the tax year being "
                    .. "filed for. SA108 box 46.",
                validation = { min = 0 },
            },
            {
                key = "sa108_losses_carried_forward",
                label = "Losses available to be carried forward",
                box = "47", order = 30,
                help = "This tax year’s capital losses – other "
                    .. "information. SA108 box 47.",
                validation = { min = 0 },
            },
            {
                key = "sa108_losses_used_earlier_year",
                label = "Losses used against an earlier year’s gain",
                box = "48", order = 40,
                help = "SA108 box 48.",
                validation = { min = 0 },
            },
            {
                key = "sa108_gains_investors_relief",
                label = "Gains qualifying for Investors’ Relief",
                box = "49", order = 50,
                help = "SA108 box 49.",
                validation = { min = 0 },
            },
            {
                key = "sa108_gains_badr",
                label = "Gains qualifying for Business Asset Disposal Relief",
                box = "50", order = 60,
                help = "SA108 box 50.",
                validation = { min = 0 },
            },
            {
                key = "sa108_badr_er_lifetime_claimed",
                label = "Lifetime allowance of Business Asset Disposal Relief and "
                    .. "Entrepreneurs’ Relief claimed – the total "
                    .. "amount claimed to date",
                box = "50.1", order = 70,
                help = "SA108 box 50.1.",
                validation = { min = 0 },
            },
        },
    },
    {
        slug = "cg-tax-adjustments",
        name = "Tax adjustments to capital gains",
        description = "SA108 page CG4. On the paper form this section names the "
            .. "tax year being filed for.",
        order = 70,
        questions = {
            {
                key = "sa108_cgt_adjustments",
                label = "Adjustments to Capital Gains Tax",
                box = "51", order = 10, negative = true,
                help = "Enter a negative number if the adjustment reduces your "
                    .. "Capital Gains Tax. SA108 box 51.",
            },
            {
                key = "sa108_nonres_trust_liability",
                label = "Additional liability for non-resident or dual resident trusts",
                box = "52", order = 20,
                help = "SA108 box 52.",
                validation = { min = 0 },
            },
        },
    },
    {
        slug = "cg-nrcgt",
        name = "Non-resident Capital Gains Tax (NRCGT) on UK property or land "
            .. "and indirect disposals",
        description = "SA108 page CG4. Please read the notes before filling in "
            .. "this section.",
        order = 80,
        questions = {
            {
                key = "sa108_nrcgt_res_direct_gains",
                label = "For direct disposals of UK residential property or "
                    .. "properties, put the total gains chargeable to NRCGT in the box",
                box = "52.1", order = 10,
                help = "SA108 box 52.1.",
                validation = { min = 0 },
            },
            {
                key = "sa108_nrcgt_nonres_indirect_gains",
                label = "For direct disposals of non-residential UK properties or "
                    .. "land, or indirect disposals of any UK properties or land, "
                    .. "put the total gains chargeable to NRCGT in the box",
                box = "52.2", order = 20,
                help = "SA108 box 52.2.",
                validation = { min = 0 },
            },
            {
                key = "sa108_nrcgt_indirect_flag",
                label = "If any of the gains in box 52.2 are from indirect "
                    .. "disposals, put ‘X’ in the box",
                box = "52.3", order = 30, qtype = "boolean",
                help = "Answering Yes is the same as putting ‘X’ "
                    .. "in the box on the paper form. SA108 box 52.3.",
            },
            {
                key = "sa108_nrcgt_tax_charged",
                label = "Tax on gains in boxes 52.1 and 52.2 already charged",
                box = "52.4", order = 40,
                help = "SA108 box 52.4.",
                validation = { min = 0 },
            },
            {
                key = "sa108_nrcgt_losses_available",
                label = "Total losses available against NRCGT gains for the year",
                box = "52.5", order = 50,
                help = "SA108 box 52.5.",
                validation = { min = 0 },
            },
        },
    },
    {
        slug = "cg-excluded-indexed-securities-and-qahc",
        name = "Excluded indexed securities and QAHC share repurchases and "
            .. "security redemptions",
        description = "SA108 page CG4: gains on excluded indexed securities and "
            .. "gains and losses on share repurchases and security redemptions "
            .. "from a qualifying asset holding company (QAHC). Details of any "
            .. "gains or losses in this section should already be included in "
            .. "the relevant sections on pages CG2 and CG3.",
        order = 90,
        questions = {
            {
                key = "sa108_exis_gains",
                label = "Total gains from the disposal of excluded indexed "
                    .. "securities – the amount before losses and reliefs",
                box = "52EG", order = 10,
                help = "SA108 box 52EG.",
                validation = { min = 0 },
            },
            {
                key = "sa108_exis_fig_claim",
                label = "Amount claimed under the foreign income and gains (FIG) regime",
                box = "52EG.1", order = 20,
                help = FIG_HELP .. " Relates to the excluded indexed securities "
                    .. "gains in box 52EG. SA108 box 52EG.1.",
                validation = { min = 0 },
            },
            {
                key = "sa108_qahc_gains",
                label = "Total gains from QAHC share repurchases and security "
                    .. "redemptions – the amount before losses and reliefs",
                box = "52QG", order = 30,
                help = "SA108 box 52QG.",
                validation = { min = 0 },
            },
            {
                key = "sa108_qahc_fig_claim",
                label = "Amount claimed under the foreign income and gains (FIG) regime",
                box = "52QG.1", order = 40,
                help = FIG_HELP .. " Relates to the QAHC gains in box 52QG. "
                    .. "SA108 box 52QG.1.",
                validation = { min = 0 },
            },
            {
                key = "sa108_qahc_losses",
                label = "Total losses from QAHC share repurchases and security redemptions",
                box = "52QL", order = 50,
                help = "SA108 box 52QL.",
                validation = { min = 0 },
            },
        },
    },
    {
        slug = "cg-any-other-information",
        name = "Any other information",
        description = "SA108 page CG4.",
        order = 100,
        questions = {
            {
                key = "sa108_estimates_valuations_flag",
                label = "If your computations include any estimates or "
                    .. "valuations, put ‘X’ in the box",
                box = "53", order = 10, qtype = "boolean",
                help = "Answering Yes is the same as putting ‘X’ "
                    .. "in the box on the paper form. SA108 box 53.",
            },
            {
                key = "sa108_other_information",
                label = "Please give any other information in this space",
                box = "54", order = 20, qtype = "long_text",
                help = "SA108 box 54.",
            },
        },
    },
}

-- Encode config_json for one question. Every question carries its
-- SA108 box mapping; currency questions also carry the same UI input
-- hint the dividends seed uses; the six headline gains boxes carry
-- card_total = true (see file header).
local function config_json_for(q)
    local cfg = {
        hmrc_mapping = { form = "SA108", box = q.box },
    }
    if (q.qtype or "currency") == "currency" then
        cfg.input = { currency = "GBP", scale = 2 }
    end
    if q.card_total then
        cfg.card_total = true
    end
    return cjson.encode(cfg)
end

-- Encode validation_json, or db.NULL when the question has none
-- (negative-allowed money boxes, booleans, free text). db.NULL —
-- never nil — because Lua truncates varargs at the first nil.
local function validation_json_for(q)
    if q.validation then
        return cjson.encode(q.validation)
    end
    return db.NULL
end

return {
    -- =========================================================================
    -- 1. Seed the ten SA108 categories (one per form section).
    --    Idempotent on slug; admin can rename freely via the admin UI.
    --    Same invariants the dividends self-heal step enforces are set
    --    correctly from the start: answer_scope='year' + tax-copilot
    --    namespace resolved by slug.
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
                    VALUES (?, ?, ?, ?, ?, ?, ?, TRUE, FALSE, 'capital_gains',
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
            "[SA108 Capital Gains] Seeded %d/%d profile categories (context='capital_gains')",
            created, #SEED
        ))
    end,

    -- =========================================================================
    -- 2. Seed the SA108 questions under their categories.
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
                print("[SA108 Capital Gains] Category missing, skipping: " .. cat.slug)
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
                                 label, help_text, question_type, is_required,
                                 is_multi_value, is_editable_by_user,
                                 display_order, config_json, validation_json,
                                 is_active, is_archived, created_at, updated_at)
                            VALUES (?, ?, ?, ?, ?, ?, ?, FALSE, FALSE, TRUE, ?,
                                    ?, ?, TRUE, FALSE, NOW(), NOW())
                        ]],
                            MigrationUtils.generateUUID(),
                            ns_id,
                            category_id,
                            q.key,
                            q.label,
                            q.help,
                            q.qtype or "currency",
                            q.order,
                            config_json_for(q),
                            validation_json_for(q)
                        )
                        created = created + 1
                    end
                end
            end
        end
        print(string.format(
            "[SA108 Capital Gains] Seeded %d/%d SA108 questions", created, total
        ))
    end,
}
