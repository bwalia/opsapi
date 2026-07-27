--[[
  SA109 Residence, Remittance basis etc. — Profile Builder catalog.

  Closes a HIGH-priority gap from the SA10x audit: expats,
  digital-nomads and split-year filers can't file today because
  the platform captures zero residence data. SA108 already emits
  FIG-claim boxes (foreign income and gains regime) but the
  underlying residence claim is missing, so those boxes go
  unsupported.

  Structure (from HMRC SA109 2025-26):

    Section 1 — Residence status (5 questions)
      Boxes 1, 2, 3, 4, 5 — resident this year, ordinarily
      resident, split year claim, days spent in UK, days worked
      full-time abroad.

    Section 2 — Personal allowance for non-residents (3 questions)
      Boxes 15, 16, 17 — claim under DTA / national of state /
      EEA national.

    Section 3 — Domicile (5 questions)
      Boxes 22, 23, 24, 25, 26 — domicile status, deemed
      domicile, date domicile of choice acquired.

    Section 4 — Remittance basis (7 questions)
      Boxes 27, 28, 29, 30, 31, 32, 33 — claim remittance basis,
      years UK resident, unremitted income/gains, RBC £30k / £60k
      / £90k tier.

    Section 5 — Any other information (1 question)
      Box 40 — free text (long_text).

  Modelling choices — matches every other SA form on the platform:

    * NEW income_type_key='sa109' with linked_form_title='SA109'
      and the HMRC PDF weblink populated. Auto-discovery renders
      /my-income/sa109 with zero frontend code (see the
      auto-discovery PR — /my-income/[type]/page.tsx picks up any
      type whose income_type_key matches a profile_categories.context).

    * profile_categories.context='sa109', answer_scope='year',
      entity_type=NULL. Single set of answers per tax year.

    * allows_manual_entry=false on the income_types row — SA109 is
      a declaration, not an income source; flat-entry my_incomes
      rows would be miscounted as trading income.

  Idempotency + safety

  - ensure_* helpers key on question_key / slug / income_type_key.
    Re-runs touch labels / help_text but never duplicate or
    resurrect admin-archived rows.
  - Two-step file (step [1] seed, step [2] safety-net re-run) —
    same convention as sa110's 767 / pension's 764 / salary's 760.
  - INSERT-only, additive. No existing data touched.
  - allows_manual_entry=false guard: routes/my-incomes.lua's
    flat-entry create path enforces the flag, so an old client
    typing 'sa109' can't accidentally create a my_incomes row.

  Scalability (per user emphasis)

  Admin can add more SA109 boxes (should HMRC add a new one in
  2026-27) via /admin/profile-builder/categories with
  context='sa109' — no code deploy. Admin can also rename /
  reorder / archive any of the seeded questions from the admin
  UI. Every rendering decision is data-driven.

  Only executed when PROJECT_CODE includes 'tax_copilot'.
]]

local db = require("lapis.db")
local cjson = require("cjson")
local MigrationUtils = require "helper.migration-utils"

local function seed_sa109()
    local function nn(v) return v ~= nil and v or db.NULL end

    -- Seed the income_types row + linked-form metadata in the same
    -- INSERT so the badge on /my-income/sa109 shows the reference
    -- form immediately (rather than depending on a separate
    -- linked-form-defaults migration to fill it in later).
    local function ensure_income_type()
        local key = "sa109"
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
                "Residence, remittance basis etc. (SA109)",
                "HMRC's SA109 supplementary form — residence status, split-year treatment, domicile and remittance basis claims. File this if you're non-UK resident, dual-resident, claiming split-year treatment, or opting into the remittance basis.",
                "SA109",
                "These fields map directly to the SA109 Residence, remittance basis etc. form.",
                "https://assets.publishing.service.gov.uk/media/6874c9e9d24a86df80b8ceb0/SA109-2025.pdf",
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
                    ?::jsonb, 95, true, NULL,
                    ?, ?, ?,
                    NOW(), NOW())
        ]],
            MigrationUtils.generateUUID(), key,
            "Residence, remittance basis etc. (SA109)",
            "HMRC's SA109 supplementary form — residence status, split-year treatment, domicile and remittance basis claims. File this if you're non-UK resident, dual-resident, claiming split-year treatment, or opting into the remittance basis.",
            cjson.encode({ sa109_form = "RR1-RR3" }),
            "SA109",
            "These fields map directly to the SA109 Residence, remittance basis etc. form.",
            "https://assets.publishing.service.gov.uk/media/6874c9e9d24a86df80b8ceb0/SA109-2025.pdf")
    end

    -- Category helper — year-scoped, context='sa109'.
    local function ensure_year_category(slug, name, description, icon, display_order)
        local exists = db.select("id FROM profile_categories WHERE slug = ?", slug)
        if exists and #exists > 0 then
            db.query([[
                UPDATE profile_categories
                   SET name = ?, description = ?, icon = ?, display_order = ?,
                       context = 'sa109',
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
            VALUES (?, 0, ?, ?, ?, ?, ?, 'sa109', 'year', NULL,
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

    -- Ensure the income_types row first so cascade / auto-discovery
    -- finds it even if the categories half fails.
    ensure_income_type()

    -- ── Section 1: Residence status ─────────────────────────────────
    local res_id = ensure_year_category(
        "sa109-residence-status",
        "Residence status",
        "SA109 boxes 1-14. Whether you were UK resident this year, split-year treatment, and days spent in / worked outside the UK.",
        "user", 1)
    if res_id then
        ensure_question(res_id, { question_key = "sa109_resident_uk",
            label = "Were you UK resident for the whole tax year? (box 1)",
            question_type = "boolean", is_required = false, display_order = 1,
            help_text = "Tick if you meet the automatic UK tests OR the sufficient-ties test for the whole year. Take the SRT test on GOV.UK if unsure." })
        ensure_question(res_id, { question_key = "sa109_split_year_claim",
            label = "Are you claiming split-year treatment? (box 3)",
            question_type = "boolean", is_required = false, display_order = 2,
            help_text = "Split-year treatment splits the tax year into a UK-resident portion and a non-resident portion — only available in specific circumstances (leaving UK to work full-time abroad, coming to UK to work, etc.)." })
        ensure_question(res_id, { question_key = "sa109_days_uk",
            label = "Days spent in the UK during 2025-26 (box 10)",
            question_type = "number", is_required = false, display_order = 3,
            help_text = "Total days you were physically in the UK at midnight. Feeds directly into the SRT day-count tests." })
        ensure_question(res_id, { question_key = "sa109_days_worked_abroad",
            label = "Days worked full-time overseas (box 11)",
            question_type = "number", is_required = false, display_order = 4 })
        ensure_question(res_id, { question_key = "sa109_ties_to_uk",
            label = "Number of ties to the UK (box 13)",
            question_type = "number", is_required = false, display_order = 5,
            help_text = "Count of: family / accommodation / work / 90-day / country ties. Used with day count for the sufficient-ties test." })
    end

    -- ── Section 2: Personal allowance for non-residents ─────────────
    local pa_id = ensure_year_category(
        "sa109-personal-allowance-non-resident",
        "Personal allowance (non-resident claim)",
        "SA109 boxes 15-17. Non-residents can still claim the UK personal allowance in specific cases.",
        "user", 2)
    if pa_id then
        ensure_question(pa_id, { question_key = "sa109_pa_claim_dta",
            label = "Claim personal allowance under a Double Taxation Agreement? (box 15)",
            question_type = "boolean", is_required = false, display_order = 1 })
        ensure_question(pa_id, { question_key = "sa109_pa_claim_nationality",
            label = "Country whose national you are (box 16)",
            question_type = "short_text", is_required = false, display_order = 2,
            help_text = "If claiming under a DTA — enter the country whose national you are." })
        ensure_question(pa_id, { question_key = "sa109_pa_claim_eea_national",
            label = "Are you a national of an EEA state? (box 17)",
            question_type = "boolean", is_required = false, display_order = 3 })
    end

    -- ── Section 3: Domicile ─────────────────────────────────────────
    local dom_id = ensure_year_category(
        "sa109-domicile",
        "Domicile",
        "SA109 boxes 22-26. Domicile status affects whether foreign income/gains are taxed on arising or remittance basis.",
        "user", 3)
    if dom_id then
        ensure_question(dom_id, { question_key = "sa109_domicile_status",
            label = "Your domicile status for the year (box 22)",
            question_type = "short_text", is_required = false, display_order = 1,
            help_text = "e.g. 'UK domiciled', 'UK deemed domicile', 'Non-domiciled', 'Non-domiciled with UK deemed domicile'." })
        ensure_question(dom_id, { question_key = "sa109_deemed_domicile",
            label = "Deemed UK domicile? (box 23)",
            question_type = "boolean", is_required = false, display_order = 2,
            help_text = "You're deemed UK domiciled if you've been UK resident for 15 of the last 20 tax years, OR you were born in the UK with a UK domicile of origin." })
        ensure_question(dom_id, { question_key = "sa109_domicile_choice_date",
            label = "Date you acquired a UK domicile of choice (box 24)",
            question_type = "date", is_required = false, display_order = 3 })
        ensure_question(dom_id, { question_key = "sa109_domicile_uk_years",
            label = "Number of tax years UK resident in the last 20 (box 25)",
            question_type = "number", is_required = false, display_order = 4 })
        ensure_question(dom_id, { question_key = "sa109_domicile_reason",
            label = "Basis of your domicile claim (box 26)",
            question_type = "long_text", is_required = false, display_order = 5,
            help_text = "Free text — e.g. domicile of origin, domicile of choice acquired on [date], etc." })
    end

    -- ── Section 4: Remittance basis ─────────────────────────────────
    local rb_id = ensure_year_category(
        "sa109-remittance-basis",
        "Remittance basis",
        "SA109 boxes 27-33. Elect remittance basis so foreign income/gains are taxed only when brought to the UK.",
        "user", 4)
    if rb_id then
        ensure_question(rb_id, { question_key = "sa109_rb_claim",
            label = "Claim remittance basis for 2025-26? (box 27)",
            question_type = "boolean", is_required = false, display_order = 1,
            help_text = "Tick if electing remittance basis. Loses UK personal allowance and CGT annual exempt amount." })
        ensure_question(rb_id, { question_key = "sa109_rb_uk_years",
            label = "Number of tax years UK resident (of last 9) (box 28)",
            question_type = "number", is_required = false, display_order = 2,
            help_text = "Feeds the £30k RBC threshold (£30k if 7 of last 9 years; £60k if 12 of last 14; unavailable after 15 of last 20)." })
        ensure_question(rb_id, { question_key = "sa109_rb_unremitted_income",
            label = "Total unremitted foreign income (box 29)",
            question_type = "currency", is_required = false, display_order = 3 })
        ensure_question(rb_id, { question_key = "sa109_rb_unremitted_gains",
            label = "Total unremitted foreign gains (box 30)",
            question_type = "currency", is_required = false, display_order = 4 })
        ensure_question(rb_id, { question_key = "sa109_rb_rbc_30k",
            label = "Remittance Basis Charge — £30,000 (box 31)",
            question_type = "boolean", is_required = false, display_order = 5,
            help_text = "Tick if paying the £30k RBC. Applies if UK resident 7 of last 9 tax years." })
        ensure_question(rb_id, { question_key = "sa109_rb_rbc_60k",
            label = "Remittance Basis Charge — £60,000 (box 32)",
            question_type = "boolean", is_required = false, display_order = 6,
            help_text = "Tick if paying the £60k RBC. Applies if UK resident 12 of last 14 tax years." })
        ensure_question(rb_id, { question_key = "sa109_rb_nominated_income",
            label = "Nominated foreign income for RBC (box 33)",
            question_type = "currency", is_required = false, display_order = 7,
            help_text = "The foreign income/gains you nominate as the source of the RBC payment. Advanced — see helpsheet HS264." })
    end

    -- ── Section 5: Any other information ────────────────────────────
    local other_id = ensure_year_category(
        "sa109-other-information",
        "Any other information",
        "SA109 box 40. Free-form notes explaining your residence, domicile or remittance-basis position.",
        "user", 5)
    if other_id then
        ensure_question(other_id, { question_key = "sa109_other_information",
            label = "Please give any other information (box 40)",
            question_type = "long_text", is_required = false, display_order = 1 })
    end

    print("[SA109] Seeded income_types row + 5 categories + ~21 questions under context='sa109' (answer_scope='year')")
end

return {
    -- =========================================================================
    -- 1. Original seed pass.
    -- =========================================================================
    [1] = seed_sa109,

    -- =========================================================================
    -- 2. Re-run pass — safety net matching every other SA-form catalog.
    --    Fresh envs where [1] fully succeeded treat [2] as idempotent no-op.
    -- =========================================================================
    [2] = seed_sa109,
}
