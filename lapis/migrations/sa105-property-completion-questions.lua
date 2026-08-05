--[[
  SA105 UK Property — completion of the missing boxes.

  The existing property-income-system.lua seed covers the LINE-ITEM
  boxes (rent, expenses per property — SA105 boxes 20-29). It does
  NOT cover the tax-adjustment and loss boxes at the tail of the
  form (32-48), which are per-tax-year TOTALS across a taxpayer's
  whole UK property portfolio — not per-property. Every leveraged
  landlord today has their residential-finance-cost 20% restriction
  (box 44) silently ignored because there's nowhere to enter it,
  and losses can't be brought forward or offset against general
  income.

  What this seeds

    Category 1 — sa105-tax-adjustments (8 currency questions)
      Private-use adjustment                    box 32
      Balancing charges                          box 33
      Annual Investment Allowance                box 34
      Business Premises Renovation Allowance     box 35
      Other capital allowances                   box 36
      Zero-emission car allowance                box 37
      Residential finance costs                  box 44
      Unused residential finance costs b/fwd     box 45

    Category 2 — sa105-property-losses (3 currency questions)
      Loss brought forward from previous year    box 46
      Loss offset against total income (2025-26) box 47
      Loss to carry forward to next year         box 48

    Plus 1 new property_line_categories row
      replacement_domestic_items  kind='expense', box 39-40

  Why year-scoped (not per-property)

  SA105 is filed ONCE per tax year covering the WHOLE UK property
  portfolio. Boxes 20-29 are naturally line-itemised (users record
  actual receipts per property), but boxes 32-48 are single
  per-year totals derived from the taxpayer's overall position
  (aggregated losses, aggregated capital-allowance claims, single
  private-use adjustment factor). Making these per-property would
  force landlords to arbitrarily split totals they think of as
  yearly.

  Under context='rental' with answer_scope='year' — renders on the
  rental HUB page (/my-income/rental), NOT on the per-property
  drill-down. This is the correct HMRC-shaped model.

  Same shape as sa110 / sa108 / sa101 catalogs — an admin adding
  more year-scoped SA105 boxes later (say if HMRC adds a new one
  in 2027-28) creates them from /admin/profile-builder/categories
  with context='rental', no code deploy.

  Idempotency + safety

  - ensure_question keys questions by question_key so re-runs
    touch labels + help_text but never duplicate rows or resurrect
    admin-archived ones.
  - Categories keyed by slug with the same semantics.
  - Two-step file (step [1] seed, step [2] safety-net re-run) —
    same convention as sa110's 767. Fresh envs where [1] fully
    succeeded treat [2] as an idempotent no-op.

  Only executed when PROJECT_CODE includes 'tax_copilot'.
]]

local db = require("lapis.db")
local MigrationUtils = require "helper.migration-utils"

local function seed_sa105_completion()
    -- nil-safe param helper — same pattern as pension / sa108 / sa110
    -- catalogs. Lua truncates varargs at the first nil so a nil
    -- description would drop trailing placeholders and leave the SQL
    -- with unbound parameters. Coerce upfront.
    local function nn(v) return v ~= nil and v or db.NULL end

    -- ── 1. Categories under context='rental', answer_scope='year' ────
    --
    -- Explicit answer_scope='year' + entity_type=NULL: rental-hub
    -- year-scoped questions. Distinct from context='rental_business'
    -- (evergreen, user-scoped) and context='property' (per-property,
    -- entity-scoped) — both of which already exist. context='rental'
    -- is new; matches income_type_key='rental' per the frontend's
    -- auto-discovery convention. Kept in step with the LinkedFormBadge
    -- (rental → SA105) already seeded by income-types-linked-form-
    -- metadata.
    local function ensure_year_category(slug, name, description, icon, display_order)
        local exists = db.select("id FROM profile_categories WHERE slug = ?", slug)
        if exists and #exists > 0 then
            db.query([[
                UPDATE profile_categories
                   SET name = ?, description = ?, icon = ?, display_order = ?,
                       context = 'rental',
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
            VALUES (?, 0, ?, ?, ?, ?, ?, 'rental', 'year', NULL,
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

    -- ── Category 1: SA105 tax adjustments and allowances ────────────
    local adj_id = ensure_year_category(
        "sa105-tax-adjustments",
        "Tax adjustments and allowances",
        "SA105 boxes 32-45. Per-year totals across your whole UK property portfolio — not per property.",
        "home", 10)
    if adj_id then
        ensure_question(adj_id, { question_key = "sa105_private_use_adjustment",
            label = "Private-use adjustment (box 32)",
            question_type = "currency", is_required = false, display_order = 1,
            help_text = "The part of your expenses that reflects your own use of the property (or a family member's) — added BACK to your taxable income." })
        ensure_question(adj_id, { question_key = "sa105_balancing_charges",
            label = "Balancing charges (box 33)",
            question_type = "currency", is_required = false, display_order = 2,
            help_text = "Any recovery of capital allowances you claimed previously — for example, from selling equipment for more than its written-down value." })
        ensure_question(adj_id, { question_key = "sa105_annual_investment_allowance",
            label = "Annual Investment Allowance (box 34)",
            question_type = "currency", is_required = false, display_order = 3,
            help_text = "AIA is only available for equipment used in FHL or commercial letting — NOT for residential lets (see box 39/40 'replacement of domestic items' for residential items instead)." })
        ensure_question(adj_id, { question_key = "sa105_bpra",
            label = "Business Premises Renovation Allowance (box 35)",
            question_type = "currency", is_required = false, display_order = 4,
            help_text = "Renovation costs for bringing a business property back into use in a disadvantaged area. Rare." })
        ensure_question(adj_id, { question_key = "sa105_other_capital_allowances",
            label = "Other capital allowances (box 36)",
            question_type = "currency", is_required = false, display_order = 5,
            help_text = "Writing-down allowances on equipment for FHL / commercial lets." })
        ensure_question(adj_id, { question_key = "sa105_zero_emission_car_allowance",
            label = "Zero-emission car allowance (box 37)",
            question_type = "currency", is_required = false, display_order = 6,
            help_text = "Enhanced first-year allowance for electric cars bought for the letting business." })
        ensure_question(adj_id, { question_key = "sa105_residential_finance_costs",
            label = "Residential finance costs (box 44)",
            question_type = "currency", is_required = false, display_order = 7,
            help_text = "Mortgage interest and other finance costs on residential property. HMRC gives you 20% tax credit on this rather than a straight deduction. Enter the FULL amount — the 20% restriction is applied automatically." })
        ensure_question(adj_id, { question_key = "sa105_unused_residential_finance_costs_bf",
            label = "Unused residential finance costs brought forward (box 45)",
            question_type = "currency", is_required = false, display_order = 8,
            help_text = "Any residential finance-cost credit you couldn't use in a prior year because your rental profit was too low. Carries forward indefinitely." })
    end

    -- ── Category 2: SA105 property losses ───────────────────────────
    local loss_id = ensure_year_category(
        "sa105-property-losses",
        "Property losses",
        "SA105 boxes 46-48. Per-year totals across your whole UK property portfolio.",
        "home", 11)
    if loss_id then
        ensure_question(loss_id, { question_key = "sa105_loss_brought_forward",
            label = "Loss brought forward from previous year (box 46)",
            question_type = "currency", is_required = false, display_order = 1,
            help_text = "Rental losses carried forward from an earlier tax year. Used against this year's rental profit first." })
        ensure_question(loss_id, { question_key = "sa105_loss_offset_general",
            label = "Loss offset against total income this year (box 47)",
            question_type = "currency", is_required = false, display_order = 2,
            help_text = "You can offset this year's rental loss against your OTHER income (salary, dividends, etc.) only if the loss arose from capital allowances or agricultural expenses. Rare." })
        ensure_question(loss_id, { question_key = "sa105_loss_carried_forward",
            label = "Loss to carry forward to next year (box 48)",
            question_type = "currency", is_required = false, display_order = 3,
            help_text = "Any remaining rental loss after this year — carries forward indefinitely against future rental profits." })
    end

    -- ── 2. Additional expense line category ─────────────────────────
    --
    -- Replacement of domestic items relief (SA105 boxes 39-40) — the
    -- rules that replaced the old wear-and-tear allowance in 2016.
    -- Applies to residential lets when you replace furniture, white
    -- goods, kitchenware etc. (like-for-like replacement, not
    -- improvements). Stored as an EXPENSE line category so users can
    -- record individual replacement receipts against a specific
    -- property, matching how they record repairs / insurance / etc.
    local domestic = {
        kind = "expense",
        key = "replacement_domestic_items",
        label = "Replacement of domestic items",
        desc = "Like-for-like replacement of furniture, appliances, kitchenware or soft furnishings in residential lets. Improvements (buying an item that's better than the one it replaces) don't qualify.",
        hmrc_mapping = '{"sa105_box":"39"}',
        order = 8,
    }
    local exists = db.select(
        "id FROM property_line_categories WHERE kind = ? AND category_key = ?",
        domestic.kind, domestic.key)
    if exists and #exists > 0 then
        db.query([[
            UPDATE property_line_categories
               SET label = ?, description = ?, hmrc_mapping = ?, display_order = ?,
                   is_active = true, updated_at = NOW()
             WHERE kind = ? AND category_key = ?
        ]], domestic.label, domestic.desc, domestic.hmrc_mapping, domestic.order,
            domestic.kind, domestic.key)
    else
        db.query([[
            INSERT INTO property_line_categories
                (uuid, kind, category_key, label, description, hmrc_mapping,
                 display_order, is_active, created_at, updated_at)
            VALUES (?, ?, ?, ?, ?, ?, ?, true, NOW(), NOW())
        ]], MigrationUtils.generateUUID(), domestic.kind, domestic.key,
            domestic.label, domestic.desc, domestic.hmrc_mapping, domestic.order)
    end

    print("[SA105 Completion] Seeded 2 year-scoped categories (11 questions) under context='rental' + 1 new expense line category (replacement_domestic_items)")
end

return {
    -- =========================================================================
    -- 1. Original seed pass. Registered as 772 in migrations.lua.
    -- =========================================================================
    [1] = seed_sa105_completion,

    -- =========================================================================
    -- 2. Re-run pass. Registered as 773 in migrations.lua. Safety net
    --    matching the convention on sa110 (767), pension (764) and
    --    salary (760). Fresh envs treat [2] as idempotent no-op.
    -- =========================================================================
    [2] = seed_sa105_completion,
}
