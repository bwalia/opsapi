--[[
  Pension Payments (TR4) — Profile Builder catalog.

  Phase 2 of the profile-builder unification (see the diy-tax-return-uk
  repo's docs/PROFILE_BUILDER_UNIFICATION_PLAN.md). Ports the pension
  payments SA100 TR4 catalogue currently held in
  pension_payment_categories + tax_form_sections/items (both live in
  parallel today) onto the unified profile_categories +
  profile_questions store, so /my-income/pension_payments can be served
  by the same engine as rental / self-employment / dividends and now
  salary.

  Shape differs from Phase 1 (salary) in an important way: pension
  payments have NO per-entity drill-down — a taxpayer just has N
  payment rows per SECTION per tax year. So this catalog uses:

    - context='pension_payments'
    - answer_scope='year'   (not 'entity' — no user_profile_entities row)
    - entity_type=NULL

  And each category is a SINGLE profile_question of type
  `repeating_group` (introduced in Phase 0 PR #796 for exactly this
  shape). The question's config_json declares the sub-fields — one
  question, many rows.

    1. pension-registered   → { description, amount, relief_at_source, one_off }
    2. pension-employer     → { description, amount }
    3. pension-overseas     → { description, amount }

  On the answer side, one user_profile_answers row per (user,
  question_id, tax_year) with answer_json = JSON array of the row
  objects the user has entered. Reads and writes go through the
  standard repeating-group widget on the frontend — zero new UI code
  needed for the render path.

  Idempotency: same helper convention as the salary catalog — keyed on
  category slug + question_key. Re-running touches labels /
  config_json but never duplicates rows or resurrects admin-archived
  ones.

  Only executed when PROJECT_CODE includes 'tax_copilot'.
]]

local db = require("lapis.db")
local cjson = require("cjson")
local MigrationUtils = require "helper.migration-utils"

-- Seed body at module scope so a re-run step (see [2] below) can call
-- it without duplicating logic. Everything inside is idempotent — the
-- re-run pass is a safety net for envs where a future edit to this
-- file (like Phase 1's varargs bug) leaves the seed half-applied.
local function seed_pension_catalog()
    -- Same nil-safe ensure_category as the salary catalog (post-fix):
    -- coerce nil description / nil icon to db.NULL BEFORE the db.query
    -- call so Lua's vararg truncation at first nil can't drop trailing
    -- placeholders. See salary-profile-builder-catalog.lua for the
    -- incident that motivated the fix.
    local function ensure_category(slug, name, description, icon, display_order)
        local desc = description ~= nil and description or db.NULL
        local ico  = icon        ~= nil and icon        or db.NULL
        local exists = db.select("id FROM profile_categories WHERE slug = ?", slug)
        if exists and #exists > 0 then
            db.query([[
                UPDATE profile_categories
                   SET name = ?, description = ?, icon = ?, display_order = ?,
                       context = 'pension_payments',
                       answer_scope = 'year',
                       entity_type = NULL,
                       is_active = true, is_archived = false, updated_at = NOW()
                 WHERE slug = ?
            ]], name, desc, ico, display_order, slug)
            return exists[1].id
        end
        db.query([[
            INSERT INTO profile_categories
                (uuid, namespace_id, name, slug, description, icon,
                 display_order, context, answer_scope, entity_type,
                 is_active, is_archived, created_at, updated_at)
            VALUES (?, 0, ?, ?, ?, ?, ?, 'pension_payments', 'year', NULL,
                    true, false, NOW(), NOW())
        ]], MigrationUtils.generateUUID(), name, slug, desc, ico, display_order)
        local row = db.select("id FROM profile_categories WHERE slug = ?", slug)
        return row and row[1] and row[1].id or nil
    end

    -- ensure_repeating_group_question upserts a single repeating_group
    -- question under `cat_id`. On UPDATE we refresh config_json + label
    -- + help_text so an admin's edit gets overwritten only by re-running
    -- THIS migration — the admin UI still owns the question. Same
    -- idempotency convention (keyed on question_key) as the salary
    -- catalog's ensure_question.
    local function ensure_repeating_group_question(cat_id, q)
        local config_str = cjson.encode(q.config)
        local help = q.help_text or ""
        local exists = db.select("id FROM profile_questions WHERE question_key = ?", q.question_key)
        if exists and #exists > 0 then
            db.query([[
                UPDATE profile_questions
                   SET category_id = ?, label = ?, question_type = 'repeating_group',
                       is_required = ?, display_order = ?, help_text = ?,
                       placeholder = '', config_json = ?,
                       is_active = true, is_archived = false, updated_at = NOW()
                 WHERE question_key = ?
            ]], cat_id, q.label, q.is_required, q.display_order, help,
                config_str, q.question_key)
            return exists[1].id
        end
        db.query([[
            INSERT INTO profile_questions
                (uuid, category_id, question_key, label, question_type, is_required,
                 display_order, help_text, placeholder, config_json,
                 is_active, version, created_at, updated_at)
            VALUES (?, ?, ?, ?, 'repeating_group', ?, ?, ?, '', ?, true, 1, NOW(), NOW())
        ]], MigrationUtils.generateUUID(), cat_id, q.question_key, q.label,
            q.is_required, q.display_order, help, config_str)
        local row = db.select("id FROM profile_questions WHERE question_key = ?", q.question_key)
        return row and row[1] and row[1].id or nil
    end

    -- ── Category 1: Registered pension schemes ──────────────────────
    -- SA100 TR4.1 / TR4.1.1 / TR4.2. Registered schemes have BOTH the
    -- relief-at-source and one-off flags; employer + overseas have
    -- neither. Sub-field keys match the tax_form_items columns so the
    -- backfill (pension-profile-builder-backfill.lua) is a direct
    -- rename map.
    local reg_id = ensure_category(
        "pension-registered",
        "Registered pension schemes",
        "Personal payments into registered pension schemes and retirement annuity contracts. Tick 'relief claimed by provider' where the scheme adds basic-rate tax relief for you (relief at source).",
        "pound-sign", 1)
    if reg_id then
        ensure_repeating_group_question(reg_id, {
            question_key = "pp_registered_payments",
            label = "Payments into registered schemes",
            is_required = false,
            display_order = 1,
            help_text = "Add one row per payment. Provider name goes in the description; amount is what YOU paid (net) — relief will be grossed up at basic rate for box TR4.1.",
            config = {
                item_label = "Payment",
                fields = {
                    { key = "description",      label = "Provider / description", type = "short_text" },
                    { key = "amount",           label = "Amount paid (net)",      type = "currency" },
                    { key = "relief_at_source", label = "Basic rate tax relief claimed by provider", type = "boolean" },
                    { key = "one_off",          label = "One-off payment",        type = "boolean" },
                },
            },
        })
    end

    -- ── Category 2: Employer schemes (net-pay-not-taken) ────────────
    -- SA100 TR4.3. Only description + amount — no flags.
    local emp_id = ensure_category(
        "pension-employer",
        "Employer schemes not deducted from gross pay",
        "Contributions to your employer's pension scheme that were taken from pay AFTER tax, so no tax relief has been given yet.",
        "pound-sign", 2)
    if emp_id then
        ensure_repeating_group_question(emp_id, {
            question_key = "pp_employer_payments",
            label = "Payments to employer schemes",
            is_required = false,
            display_order = 1,
            help_text = "Only include contributions taken from your pay AFTER tax (usually shown as 'net' on your payslip). Pre-tax contributions are already relieved via PAYE and go nowhere on the return.",
            config = {
                item_label = "Payment",
                fields = {
                    { key = "description", label = "Provider / description", type = "short_text" },
                    { key = "amount",      label = "Amount paid",            type = "currency" },
                },
            },
        })
    end

    -- ── Category 3: Overseas schemes ────────────────────────────────
    -- SA100 TR4.4. Same shape as employer.
    local ovr_id = ensure_category(
        "pension-overseas",
        "Overseas schemes eligible for UK tax relief",
        "Payments to a qualifying overseas pension scheme, paid out of taxed income and eligible for UK tax relief.",
        "pound-sign", 3)
    if ovr_id then
        ensure_repeating_group_question(ovr_id, {
            question_key = "pp_overseas_payments",
            label = "Payments to overseas schemes",
            is_required = false,
            display_order = 1,
            help_text = "Only qualifying overseas schemes recognised by HMRC. Amounts must be paid out of already-taxed income.",
            config = {
                item_label = "Payment",
                fields = {
                    { key = "description", label = "Provider / description", type = "short_text" },
                    { key = "amount",      label = "Amount paid",            type = "currency" },
                },
            },
        })
    end

    print("[Pension → Profile Builder] Seeded 3 categories, 3 repeating_group questions under context='pension_payments' (answer_scope='year')")
end

return {
    -- =========================================================================
    -- 1. Original seed pass. Registered as 762 in migrations.lua.
    -- =========================================================================
    [1] = seed_pension_catalog,

    -- =========================================================================
    -- 2. Re-run pass. Registered as 764 in migrations.lua. Safety net
    --    for future edits to this file that could leave the seed half-
    --    applied (see the salary catalog's 760 for the incident that
    --    established this convention).
    -- =========================================================================
    [2] = seed_pension_catalog,
}
