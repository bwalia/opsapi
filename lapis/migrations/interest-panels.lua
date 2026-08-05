--[[
  Interest panels — two income-type tabs, each an itemised table.

    /my-income/interest          "Bank interest"     — UK banks and building societies
    /my-income/foreign_interest  "Foreign interest"  — overseas savings (new type)

  FOLLOW-ON FROM dividend-panels.lua
    That migration retired the old "Dividends and interest" category of 7
    flat boxes. Boxes 1-3 of it were INTEREST (taxed UK / untaxed UK /
    untaxed foreign), deactivated there with the note that interest wants
    its own itemised panel under context='interest'. This is that panel.
    Nothing is double-entered: those boxes are already inactive, so the
    tables below are the only place interest is captured.

  WHY TWO TYPES RATHER THAN TWO CATEGORIES ON ONE PAGE
    Same reasoning as the dividend tabs: an income_type row is what
    earns a tab on /my-income, a card + total on the overview, and its
    own document routing. Auto-discovery does the rest — the frontend
    convention is `income_type_key IS the profile-builder context`
    (app/my-income/[type]/page.tsx), so seeding a category with
    context='foreign_interest' is all it takes to render
    /my-income/foreign_interest. Zero frontend routing code.

    UK interest stays ONE page with two tables because untaxed and
    taxed interest are the same transcription job off the same
    statements — the supplied screen shows both stacked, and splitting
    them would make a user with one of each visit two tabs.

  SIDE EFFECT OF ADDING A CONTEXT
    /my-income/interest currently renders the flat-entry list (one
    amount per my_incomes row). Seeding a category with
    context='interest' switches that page into profile-builder mode.
    Existing my_incomes rows for the type are NOT deleted — they stay
    in the DB, readable and exportable — but the flat Add-income
    surface stops rendering, which is the point: the figures are
    itemised per account now. Same trade dividend-panels.lua made.

  BOX MAPPING
    Every question keeps its HMRC mapping in config_json.hmrc_mapping
    alongside `total_field` — the sub-field whose column total IS the
    box figure:

      int_untaxed_uk   SA100 box 2   total of `amount`
      int_taxed_uk     SA100 box 1   total of `net`
      fint_savings     SA106 box 3   total of `gross_income`

    The filing worker reads that; nothing user-facing mentions a form
    or a box number, by design.

    SA100 box 1 wants the NET figure. The Tax column alongside it is
    what the bank deducted — it doesn't have its own SA100 box (HMRC
    grosses box 1 up), but it belongs on the row: users transcribe it
    off the certificate, and the calculation needs it as tax already
    paid. Kept as a totalled column rather than dropped.

  WIDGET CONTRACT
    Each panel is ONE question of type `repeating_group` whose
    config_json declares the columns. `layout = "table"` renders the
    grid: column headers, inline row inputs, a totals footer for
    `total = true` columns, checkbox cells for `display = "checkbox"`
    booleans, and read-only computed cells (see RepeatingGroupField.tsx).
    Answers land as one user_profile_answers row per (user, question,
    tax_year) holding a JSON array of row objects.

  SA106 (context='foreign_income') is deliberately NOT touched. It
  keeps its own "Foreign savings interest" section (boxes 3-5 as three
  flat totals) for people filing the full supplementary form — exactly
  the split dividend-panels.lua made with foreign dividends.

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

local UNTAXED_UK_FIELDS = {
    { key = "description",    label = "Description",    type = "short_text", required = true,
      placeholder = "e.g. Loyalty Saver" },
    { key = "account_number", label = "Account number", type = "short_text",
      placeholder = "e.g. 270037140" },
    { key = "amount",         label = "Amount",         type = "currency", total = true },
}

local TAXED_UK_FIELDS = {
    { key = "description",    label = "Description",    type = "short_text", required = true,
      placeholder = "e.g. Reward Saver" },
    { key = "account_number", label = "Account number", type = "short_text",
      placeholder = "e.g. 57682563" },
    { key = "net",            label = "Net",            type = "currency", total = true,
      help_text = "What reached your account, after the bank took tax off." },
    { key = "tax",            label = "Tax",            type = "currency", total = true,
      help_text = "The tax the bank deducted, shown on your interest certificate." },
}

local FOREIGN_INTEREST_FIELDS = {
    { key = "country",      label = "Country",              type = "short_text",
      placeholder = "e.g. United States", required = true },
    { key = "description",  label = "Description of income", type = "short_text",
      placeholder = "e.g. Chase savings 8842" },
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
          -- same tax twice. Same rule the foreign dividends panel uses.
          subtract_unless = { { field = "foreign_tax", unless_flag = "ftcr_claim" } },
      },
      help_text = "Worked out for you from the amounts on this row." },
    { key = "ftcr_claim", label = "Claim Foreign Tax Credit Relief?", type = "boolean",
      display = "checkbox",
      help_text = "Claims credit for the foreign tax against your UK tax on the same interest." },
    { key = "pre_2025_remitted", label = "Pre 6 April 2025 income remitted this year?",
      type = "boolean", display = "checkbox" },
}

-- income_types row for the NEW tab. `interest` already exists (seeded
-- by income-types-system.lua) and is updated in place below.
local NEW_INCOME_TYPES = {
    {
        key = "foreign_interest",
        label = "Foreign interest",
        description = "Interest from banks and savings accounts outside the UK.",
        order = 51,
        docs = {
            { key = "interest_certificate", label = "Interest certificate",           required = false },
            { key = "broker_statements",    label = "Bank / broker statements",       required = false },
        },
    },
}

local function seed_interest_panels()
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
        -- Fail loudly on missing args. Previously a dropped positional
        -- argument left display_order = nil, which propagated into
        -- `db.query` and blew up as "db.interpolate_query: missing
        -- replacement 6" — a message that told you which placeholder
        -- was starved but not which parameter, so the caller wasn't
        -- obviously the culprit. Assert here surfaces the caller in
        -- the traceback and names the missing field.
        assert(context ~= nil and context ~= "",
            "ensure_year_category: `context` is required (used for /my-income/<type> auto-discovery)")
        assert(slug ~= nil and slug ~= "",
            "ensure_year_category: `slug` is required (used for the profile_categories key)")
        assert(name ~= nil and name ~= "",
            "ensure_year_category: `name` is required (rendered in the section header)")
        assert(display_order ~= nil,
            "ensure_year_category: `display_order` is required (integer, drives left-to-right order)")
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

    -- The existing interest tab keeps its key (URLs and any stored
    -- income_type references stay valid) but switches to itemised
    -- capture: manual one-amount entry off, description reworded to
    -- say the figures are per account now.
    db.query([[
        UPDATE income_types
           SET display_name = 'Bank interest',
               description = 'Interest from UK banks and building societies, listed per account.',
               allows_manual_entry = false,
               linked_form_title = NULL,
               linked_form_description = NULL,
               linked_form_weblink = NULL,
               is_active = true, updated_at = NOW()
         WHERE income_type_key = 'interest'
    ]])

    -- ── Tab 1, section 1: Untaxed UK interest ───────────────────────
    -- Interest paid gross. Since April 2016 that is nearly every UK
    -- bank and building society account, so this table leads.
    --
    -- `context = "interest"` matches the income_type_key so
    -- app/my-income/[type]/page.tsx auto-discovers this category when
    -- the URL is /my-income/interest — that's the header's
    -- "income_type_key IS the profile-builder context" contract.
    local untaxed_id = ensure_year_category(
        "interest",
        "interest-untaxed-uk",
        "Untaxed UK interest",
        "Interest paid without tax taken off — most UK bank and building society accounts since April 2016. One row per account.",
        "pound-sign", 1)
    if untaxed_id then
        ensure_question(untaxed_id, {
            question_key = "int_untaxed_uk",
            label = "Untaxed UK interest",
            question_type = "repeating_group",
            is_required = false,
            display_order = 1,
            help_text = "Copy each account from your interest certificate or your bank's end-of-year summary. The amount is the interest credited during the tax year.",
            config = table_config(UNTAXED_UK_FIELDS, "Account", "Add another account",
                "SA100", "2", "amount"),
        })
    end

    -- ── Tab 1, section 2: Taxed UK interest ─────────────────────────
    -- Rarer post-2016 but still real: some annuities, PPI interest,
    -- compensation payments and trust income arrive net of tax.
    local taxed_id = ensure_year_category(
        "interest",
        "interest-taxed-uk",
        "Taxed UK interest",
        "Interest that already had UK tax taken off before it reached you. Enter what you received and the tax deducted — both are on the certificate.",
        "pound-sign", 2)
    if taxed_id then
        ensure_question(taxed_id, {
            question_key = "int_taxed_uk",
            label = "Taxed UK interest",
            question_type = "repeating_group",
            is_required = false,
            display_order = 1,
            help_text = "Leave this table empty if every account paid you gross. Net is what reached you; tax is what was deducted — don't add them together yourself.",
            config = table_config(TAXED_UK_FIELDS, "Account", "Add another account",
                "SA100", "1", "net"),
        })
    end

    -- ── Tab 1, section 3: Additional information ────────────────────
    -- The supplied screen carries one free-text note under both
    -- tables, not one per table — its own section keeps that scope
    -- obvious rather than making it look like a footnote to the
    -- taxed table.
    local notes_id = ensure_year_category(
        "interest",
        "interest-notes",
        "Additional information",
        "Anything you want to explain to HMRC about your interest.",
        "file-text", 3)
    if notes_id then
        ensure_question(notes_id, {
            question_key = "int_notes",
            label = "Additional text note for Tax Return",
            question_type = "long_text",
            is_required = false,
            display_order = 1,
            help_text = "Optional. Sent with your return — use it for anything the figures above don't explain on their own.",
        })
    end

    -- ── Tab 2: Foreign interest ─────────────────────────────────────
    -- `context = "foreign_interest"` matches the NEW income_type_key
    -- seeded above so /my-income/foreign_interest picks up this
    -- category. Same convention as the interest tab above.
    local fi_id = ensure_year_category(
        "foreign_interest",
        "foreign-savings-interest",
        "Foreign savings interest",
        "One row per overseas account. Amounts in sterling — convert at the rate on the date you were paid.",
        "globe", 1)
    if fi_id then
        -- Page-level election. Ticking it is what makes the "Relief
        -- claimed under the FIG regime" column meaningful; the column
        -- stays editable either way rather than trapping anyone
        -- behind a toggle they forgot to set. Mirrors the foreign
        -- dividends panel.
        ensure_question(fi_id, {
            question_key = "fint_fig_regime_relief",
            label = "Relief claimed under FIG regime?",
            question_type = "boolean",
            is_required = false,
            display_order = 1,
            help_text = "The Foreign Income and Gains regime for new UK residents. Tick only if you qualify and are claiming it.",
        })
        ensure_question(fi_id, {
            question_key = "fint_savings_interest",
            label = "Foreign savings interest",
            question_type = "repeating_group",
            is_required = false,
            display_order = 2,
            help_text = "The taxable amount is worked out for you: gross income, less any FIG-regime relief, less foreign tax where you are not claiming Foreign Tax Credit Relief on it.",
            config = table_config(FOREIGN_INTEREST_FIELDS, "Account", "Add another account",
                "SA106", "3", "gross_income"),
        })
        ensure_question(fi_id, {
            question_key = "fint_notes",
            label = "Additional text note for Tax Return",
            question_type = "long_text",
            is_required = false,
            display_order = 3,
            help_text = "Optional. Sent with your return — a good place to record the exchange rates you used.",
        })
    end

    print("[Interest panels] Seeded 2 interest tabs (interest / foreign_interest)")
end

return {
    -- =========================================================================
    -- 1. Seed pass. Registered as 793 in migrations.lua.
    -- =========================================================================
    [1] = seed_interest_panels,

    -- =========================================================================
    -- 2. Re-run pass. Registered as 794. Safety net for a later edit to
    --    this file leaving the seed half-applied in an environment that
    --    already recorded 793 as run — the convention every catalog seed
    --    here follows (see 760 / 764 / 767 / 792).
    -- =========================================================================
    [2] = seed_interest_panels,
}
