--[[
  Dividend panels — three income-type tabs, each an itemised table.

    /my-income/dividends          "Dividends"        — dividends from UK companies
    /my-income/foreign_dividends  "Foreign dividends" — dividends from foreign companies
    /my-income/other_dividends    "Other dividends"   — unit trusts, OEICs, collectives

  WHY THREE TYPES RATHER THAN THREE CATEGORIES ON ONE PAGE
    Each is its own income_type row, so each gets its own tab on
    /my-income, its own card + total on the overview, and its own
    document routing. Auto-discovery does the rest: the frontend
    convention is `income_type_key IS the profile-builder context`
    (see app/my-income/[type]/page.tsx), so seeding a category with
    context='foreign_dividends' is all it takes to render
    /my-income/foreign_dividends. Zero frontend routing code.

  WHAT REPLACES WHAT
    context='dividends' previously held ONE category ("Dividends and
    interest") of 7 flat currency boxes seeded by
    sa100-dividend-questions.lua. All 7 are deactivated here and the
    category is archived — the dividend figures are now itemised
    per holding, and the panels are modelled on the screens the
    product owner supplied rather than on the paper form's box list.
    Deactivated, never deleted: user_profile_answers rows survive, so
    an admin can re-activate any box from /admin/profile-builder if a
    figure needs recovering.

    Boxes 1-3 of that old category were INTEREST, not dividends
    (taxed UK interest / untaxed UK interest / untaxed foreign
    interest). They are deactivated with the rest — a dividends tab
    showing interest boxes was the thing this change is removing. If
    interest needs its own itemised panel later it belongs under
    context='interest', which is a separate piece of work: adding a
    profile-builder context to that type also switches its page out
    of flat-entry mode.

    SA106 (context='foreign_income') is deliberately NOT touched. It
    keeps its own "Dividends from foreign companies" section for
    people filing the full supplementary form.

  BOX MAPPING
    Every question keeps its HMRC mapping in config_json.hmrc_mapping
    alongside `total_field` — the sub-field whose column total IS the
    box figure. The filing worker reads that; nothing user-facing
    mentions a form or a box number, by design.

  WIDGET CONTRACT
    Each panel is ONE question of type `repeating_group` whose
    config_json declares the columns. `layout = "table"` renders the
    IRIS-style grid: column headers, inline row inputs, a totals
    footer for `total = true` columns, checkbox cells for
    `display = "checkbox"` booleans, and read-only computed cells
    (see RepeatingGroupField.tsx). Answers land as one
    user_profile_answers row per (user, question, tax_year) holding a
    JSON array of row objects — same storage shape pension payments
    has used since Phase 2.

  Idempotent: keyed on income_type_key / category slug / question_key.
  Re-running refreshes labels + column config but never duplicates.

  Only executed when PROJECT_CODE includes 'tax_copilot'.
]]

local db = require("lapis.db")
local cjson = require("cjson")
local MigrationUtils = require "helper.migration-utils"

-- Column sets. Each mirrors one of the supplied screens 1:1 — column
-- order, labels and which columns carry a total are all deliberate.
--
-- `total = true`  → the column gets a summed footer cell, and the
--                   frontend counts it toward the page's headline
--                   figure (ContextSections.numericTotal).
-- `display`       → "checkbox" keeps a boolean to one cell's width;
--                   the default Yes/No chip pair is too wide here.
-- `computed`      → read-only cell derived from its siblings:
--                     base − Σ subtract − Σ (subtract_unless whose
--                     `unless_flag` column is unticked)
--                   Declarative on purpose: no formula parser, and an
--                   admin can retarget it from the admin panel.

local UK_DIVIDEND_FIELDS = {
    { key = "description", label = "Description", type = "short_text",
      placeholder = "e.g. GSK PLC ORD 31 1/4p" },
    { key = "shares_held", label = "Shares held", type = "number" },
    { key = "date_paid",   label = "Date paid",   type = "date" },
    { key = "dividend",    label = "Dividend",    type = "currency", total = true },
    { key = "all_shares_disposed", label = "All shares disposed", type = "boolean",
      display = "checkbox",
      help_text = "Tick if you sold every one of these shares during the year." },
}

local FOREIGN_DIVIDEND_FIELDS = {
    { key = "country",      label = "Country",            type = "short_text",
      placeholder = "e.g. United States", required = true },
    { key = "description",  label = "Description of income", type = "short_text" },
    { key = "gross_income", label = "Gross income arising", type = "currency", total = true },
    { key = "fig_relief",   label = "Relief claimed under the FIG regime", type = "currency", total = true },
    { key = "foreign_tax",  label = "Foreign tax taken off", type = "currency", total = true },
    { key = "uk_tax",       label = "UK tax taken off",      type = "currency", total = true },
    { key = "taxable_amount", label = "Taxable amount", type = "currency", total = true,
      computed = {
          base = "gross_income",
          subtract = { "fig_relief" },
          -- Foreign tax is only deductible from the taxable amount
          -- when you are NOT claiming Foreign Tax Credit Relief on
          -- it — claiming FTCR credits it against the UK bill
          -- instead, so deducting it here as well would relieve the
          -- same tax twice.
          subtract_unless = { { field = "foreign_tax", unless_flag = "ftcr_claim" } },
      },
      help_text = "Worked out for you from the amounts on this row." },
    { key = "ftcr_claim", label = "Claim Foreign Tax Credit Relief?", type = "boolean",
      display = "checkbox",
      help_text = "Claims credit for the foreign tax against your UK tax on the same dividend." },
    { key = "pre_2016_remitted", label = "Pre 2016 dividend remitted this year?",
      type = "boolean", display = "checkbox" },
}

local OTHER_DIVIDEND_FIELDS = {
    { key = "description", label = "Description", type = "short_text",
      placeholder = "e.g. Aviva Shareholder no: C0004329392" },
    { key = "dividend_received", label = "Dividend received", type = "currency", total = true },
    { key = "all_shares_disposed", label = "All shares disposed", type = "boolean",
      display = "checkbox",
      help_text = "Tick if you sold every one of these holdings during the year." },
}

-- income_types rows for the two NEW tabs. `dividends` already exists
-- (seeded by income-types-system.lua) and is updated in place below.
local NEW_INCOME_TYPES = {
    {
        key = "foreign_dividends",
        label = "Foreign dividends",
        description = "Dividends from companies based outside the UK.",
        order = 31,
        docs = {
            { key = "dividend_vouchers", label = "Dividend vouchers",            required = false },
            { key = "broker_statements", label = "Broker / platform statements", required = false },
        },
    },
    {
        key = "other_dividends",
        label = "Other dividends",
        description = "Dividends from authorised unit trusts, open-ended investment companies and other collective investments.",
        order = 32,
        docs = {
            { key = "dividend_vouchers", label = "Dividend vouchers",              required = false },
            { key = "fund_statements",   label = "Unit trust / fund statements",   required = false },
        },
    },
}

local function seed_dividend_panels()
    local function nn(v) return v ~= nil and v or db.NULL end

    -- ── income_types ────────────────────────────────────────────────
    -- allows_manual_entry = false: these tabs capture itemised rows
    -- through the profile builder, not one-amount-per-row my_incomes
    -- entries. linked_form_* left NULL so no reference-form card
    -- renders — the panels stand on their own copy.
    local function ensure_income_type(t)
        local exists = db.select("id FROM income_types WHERE income_type_key = ?", t.key)
        if exists and #exists > 0 then
            db.query([[
                UPDATE income_types
                   SET display_name = ?, description = ?,
                       required_documents = ?::jsonb,
                       allows_manual_entry = false,
                       display_order = ?, is_active = true, updated_at = NOW()
                 WHERE income_type_key = ?
            ]], t.label, t.description, cjson.encode(t.docs), t.order, t.key)
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
                    ?::jsonb, false,
                    '[]'::jsonb, '{}'::jsonb, NULL,
                    '{}'::jsonb, ?, true, NULL,
                    NOW(), NOW())
        ]], MigrationUtils.generateUUID(), t.key, t.label, t.description,
            cjson.encode(t.docs), t.order)
    end

    local function ensure_year_category(context, slug, name, description, icon, display_order)
        local exists = db.select("id FROM profile_categories WHERE slug = ?", slug)
        if exists and #exists > 0 then
            db.query([[
                UPDATE profile_categories
                   SET name = ?, description = ?, icon = ?, display_order = ?,
                       context = ?, answer_scope = 'year', entity_type = NULL,
                       is_active = true, is_archived = false, updated_at = NOW()
                 WHERE slug = ?
            ]], name, nn(description), nn(icon), display_order, context, slug)
            return exists[1].id
        end
        db.query([[
            INSERT INTO profile_categories
                (uuid, namespace_id, name, slug, description, icon,
                 display_order, context, answer_scope, entity_type,
                 is_active, is_archived, created_at, updated_at)
            VALUES (?, 0, ?, ?, ?, ?, ?, ?, 'year', NULL,
                    true, false, NOW(), NOW())
        ]], MigrationUtils.generateUUID(), name, slug, nn(description),
            nn(icon), display_order, context)
        local row = db.select("id FROM profile_categories WHERE slug = ?", slug)
        return row and row[1] and row[1].id or nil
    end

    -- Upsert one question. `config` is optional (the notes questions
    -- carry none). Re-running refreshes label / help / config so a
    -- column tweak in this file reaches every environment.
    local function ensure_question(cat_id, q)
        local config_str = q.config and cjson.encode(q.config) or db.NULL
        local exists = db.select("id FROM profile_questions WHERE question_key = ?", q.question_key)
        if exists and #exists > 0 then
            db.query([[
                UPDATE profile_questions
                   SET category_id = ?, label = ?, question_type = ?, is_required = ?,
                       display_order = ?, help_text = ?, placeholder = '',
                       config_json = ?, is_active = true, is_archived = false,
                       updated_at = NOW()
                 WHERE question_key = ?
            ]], cat_id, q.label, q.question_type, q.is_required, q.display_order,
                q.help_text or "", config_str, q.question_key)
            return exists[1].id
        end
        db.query([[
            INSERT INTO profile_questions
                (uuid, category_id, question_key, label, question_type, is_required,
                 display_order, help_text, placeholder, config_json,
                 is_active, is_archived, version, created_at, updated_at)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, '', ?, true, false, 1, NOW(), NOW())
        ]], MigrationUtils.generateUUID(), cat_id, q.question_key, q.label,
            q.question_type, q.is_required, q.display_order, q.help_text or "",
            config_str)
        local row = db.select("id FROM profile_questions WHERE question_key = ?", q.question_key)
        return row and row[1] and row[1].id or nil
    end

    -- Table config for a panel: the column set plus the labels the
    -- add-row affordances use.
    local function table_config(fields, item_label, add_label, hmrc_form, hmrc_box, total_field)
        return {
            layout = "table",
            item_label = item_label,
            add_button_label = add_label,
            fields = fields,
            -- Filing metadata. Not rendered anywhere: the column
            -- total named by `total_field` is what the worker puts in
            -- the box.
            hmrc_mapping = { form = hmrc_form, box = hmrc_box, total_field = total_field },
        }
    end

    for _, t in ipairs(NEW_INCOME_TYPES) do ensure_income_type(t) end

    -- The existing dividends tab keeps its key (URLs and any stored
    -- income_type references stay valid) but loses its paper-form
    -- framing: description reworded, reference-form card cleared,
    -- manual entry off now that rows are itemised.
    db.query([[
        UPDATE income_types
           SET display_name = 'Dividends',
               description = 'Dividends from UK companies, listed per holding.',
               allows_manual_entry = false,
               linked_form_title = NULL,
               linked_form_description = NULL,
               linked_form_weblink = NULL,
               is_active = true, updated_at = NOW()
         WHERE income_type_key = 'dividends'
    ]])

    -- ── Tab 1: Dividends (UK companies) ─────────────────────────────
    local uk_id = ensure_year_category(
        "dividends",
        "dividends-uk-companies",
        "Dividends from UK companies",
        "One row per holding — the description, the shares you held, the date paid and the dividend received.",
        "pound-sign", 1)
    if uk_id then
        ensure_question(uk_id, {
            question_key = "div_uk_dividends",
            label = "Dividends from UK companies",
            question_type = "repeating_group",
            is_required = false,
            display_order = 1,
            help_text = "Copy each line from your dividend vouchers. The dividend is the amount you received.",
            config = table_config(UK_DIVIDEND_FIELDS, "Dividend", "Add another dividend",
                "SA100", "4", "dividend"),
        })
        ensure_question(uk_id, {
            question_key = "div_uk_notes",
            label = "Additional text note for Tax Return",
            question_type = "long_text",
            is_required = false,
            display_order = 2,
            help_text = "Anything you want to explain to HMRC about these dividends. Sent with your return.",
        })
    end

    -- ── Tab 2: Foreign dividends ────────────────────────────────────
    local fd_id = ensure_year_category(
        "foreign_dividends",
        "foreign-dividends-companies",
        "Dividends from foreign companies",
        "One row per foreign holding. Amounts in sterling — convert at the rate on the date you were paid.",
        "globe", 1)
    if fd_id then
        -- Page-level election. Ticking it is what makes the "Relief
        -- claimed under the FIG regime" column meaningful; the column
        -- stays editable either way rather than trapping anyone
        -- behind a toggle they forgot to set.
        ensure_question(fd_id, {
            question_key = "fdiv_fig_regime_relief",
            label = "Relief claimed under FIG regime?",
            question_type = "boolean",
            is_required = false,
            display_order = 1,
            help_text = "The Foreign Income and Gains regime for new UK residents. Tick only if you qualify and are claiming it.",
        })
        ensure_question(fd_id, {
            question_key = "fdiv_dividends",
            label = "Dividends from foreign companies",
            question_type = "repeating_group",
            is_required = false,
            display_order = 2,
            help_text = "The taxable amount is worked out for you: gross income, less any FIG-regime relief, less foreign tax where you are not claiming Foreign Tax Credit Relief on it.",
            config = table_config(FOREIGN_DIVIDEND_FIELDS, "Dividend", "Add another dividend",
                "SA106", "6", "gross_income"),
        })
    end

    -- ── Tab 3: Other dividends ──────────────────────────────────────
    local od_id = ensure_year_category(
        "other_dividends",
        "other-dividends",
        "Other dividends",
        "Authorised unit trusts, open-ended investment companies and other collective investments.",
        "pound-sign", 1)
    if od_id then
        ensure_question(od_id, {
            question_key = "odiv_dividends",
            label = "Other dividends",
            question_type = "repeating_group",
            is_required = false,
            display_order = 1,
            help_text = "One row per distribution. Use the description to identify the fund or shareholder reference.",
            config = table_config(OTHER_DIVIDEND_FIELDS, "Dividend", "Add another dividend",
                "SA100", "5", "dividend_received"),
        })
        ensure_question(od_id, {
            question_key = "odiv_notes",
            label = "Additional text note for Tax Return",
            question_type = "long_text",
            is_required = false,
            display_order = 2,
            help_text = "Anything you want to explain to HMRC about these dividends. Sent with your return.",
        })
    end

    -- ── Retire the old flat boxes ───────────────────────────────────
    -- Deactivated, not deleted: /schema skips inactive questions so
    -- they vanish from the page, while every user_profile_answers row
    -- stays readable in the DB and re-activatable from the admin
    -- panel. Scoped by question_key prefix + the old category slug so
    -- nothing else named sa100_* elsewhere is caught.
    db.query([[
        UPDATE profile_questions q
           SET is_active = false, updated_at = NOW()
          FROM profile_categories c
         WHERE q.category_id = c.id
           AND c.slug = 'dividends-and-interest'
           AND q.question_key LIKE 'sa100_%'
           AND q.is_active = true
    ]])
    db.query([[
        UPDATE profile_categories
           SET is_active = false, is_archived = true, updated_at = NOW()
         WHERE slug = 'dividends-and-interest'
           AND (is_active = true OR is_archived = false)
    ]])

    print("[Dividend panels] Seeded 3 dividend tabs (dividends / foreign_dividends / other_dividends) and retired the old flat dividend boxes")
end

return {
    -- =========================================================================
    -- 1. Seed pass. Registered as 791 in migrations.lua.
    -- =========================================================================
    [1] = seed_dividend_panels,

    -- =========================================================================
    -- 2. Re-run pass. Registered as 792. Safety net for a later edit to
    --    this file leaving the seed half-applied in an environment that
    --    already recorded 791 as run — the convention every catalog seed
    --    here follows (see 760 / 764 / 767).
    -- =========================================================================
    [2] = seed_dividend_panels,
}
