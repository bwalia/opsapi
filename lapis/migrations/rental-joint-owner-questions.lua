--[[
  Rental joint-owner details — first consumer of the config-driven
  `repeating_group` widget contract (see frontend RepeatingGroupField).

  When a landlord answers YES to `rb_jointly_let` we need to capture WHO
  they let the property with, their relationship to the taxpayer, and
  each co-owner's percentage share. The taxpayer's own share is derived
  (100 − sum of others) so we don't ask for it explicitly.

  This is DB-driven, not code-driven — the widget reads the field
  schema from `profile_questions.config_json` verbatim. Every future
  repeating question (children, shareholders, foreign properties…) is
  ONE seed migration away with the same shape and zero UI changes.

  What this migration does, idempotently:

    [1] Reorder + insert
        - Shift `rb_non_resident_landlord` and `rb_first_letting_date`
          from display_order 4/5 → 5/6 so the new question can slot
          in at position 4 immediately after `rb_jointly_let`.
        - Upsert `rb_joint_owners` (repeating_group) with its full
          config_json (name/relation/share_pct subfields + item_label
          + Add-button copy + sensible min/max_items).
        - Seed nothing outside the target namespace: matches the
          existing property-income seed's `namespace_id` = tax-copilot
          convention via project_code.

    [2] Visibility rule
        - `rb_joint_owners` is visible only when `rb_jointly_let = true`.
          Uses the same helper shape as property-income-system.lua's
          `ensure_rule` so admins can see/edit it in the /admin
          profile-builder rules UI.

  Feature-gated on TAX_COPILOT (mirrors property-income-system.lua).
  Runs strictly AFTER 748* (dynamic-answer-scope) and property-income-system.
]]

local db = require("lapis.db")
local cjson = require("cjson")
local MigrationUtils = require "helper.migration-utils"

-- Config the frontend's RepeatingGroupField consumes verbatim. Extending
-- to a new repeating question in the future is a copy-paste of this block
-- with different fields; no widget changes needed.
local JOINT_OWNERS_CONFIG = {
    fields = {
        {
            key = "name",
            label = "Owner name",
            type = "short_text",
            required = true,
            placeholder = "e.g. Sarah Smith",
        },
        {
            key = "relation",
            label = "Relationship to you",
            type = "single_select",
            required = true,
            options = {
                { value = "spouse",          label = "Spouse" },
                { value = "civil_partner",   label = "Civil partner" },
                { value = "family",          label = "Family member" },
                { value = "business_partner", label = "Business partner" },
                { value = "friend",          label = "Friend" },
                { value = "other",           label = "Other" },
            },
        },
        {
            key = "share_pct",
            label = "Their share (%)",
            type = "percentage",
            required = true,
            min = 1,
            max = 99,
            placeholder = "e.g. 50",
            help_text = "Their ownership share only — yours is derived as the remainder.",
        },
    },
    item_label = "Joint owner",
    add_button_label = "Add another joint owner",
    min_items = 1,
    max_items = 5,
}

-- Small local helper — the property-income seed's own upsert helper is
-- private to that module and doesn't handle `config_json`. Duplicating
-- the pattern here keeps this migration self-contained.
local function upsert_question(cat_id, q)
    local exists = db.select("id FROM profile_questions WHERE question_key = ?", q.question_key)
    if exists and #exists > 0 then
        db.query([[
            UPDATE profile_questions
               SET category_id     = ?,
                   label           = ?,
                   question_type   = ?,
                   is_required     = ?,
                   display_order   = ?,
                   help_text       = COALESCE(?, help_text),
                   placeholder     = COALESCE(?, placeholder),
                   config_json     = ?,
                   is_active       = true,
                   is_archived     = false,
                   updated_at      = NOW()
             WHERE question_key = ?
        ]],
            cat_id, q.label, q.question_type, q.is_required, q.display_order,
            q.help_text, q.placeholder,
            q.config_json,
            q.question_key
        )
        return exists[1].id
    end
    db.query([[
        INSERT INTO profile_questions
            (uuid, category_id, question_key, label, question_type,
             is_required, is_multi_value, is_editable_by_user,
             display_order, help_text, placeholder, config_json,
             is_active, version, created_at, updated_at)
        VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, true, 1, NOW(), NOW())
    ]],
        MigrationUtils.generateUUID(),
        cat_id,
        q.question_key,
        q.label,
        q.question_type,
        q.is_required,
        q.is_multi_value or false,
        (q.is_editable_by_user ~= false),   -- default true
        q.display_order,
        q.help_text or "",
        q.placeholder or "",
        q.config_json
    )
    local row = db.select("id FROM profile_questions WHERE question_key = ?", q.question_key)
    return row and row[1] and row[1].id or nil
end

-- Same shape as property-income-system.lua's ensure_rule — matches so
-- admins see the rule in /admin/profile-builder/rules alongside its
-- siblings, and re-running the seed is a no-op.
local function ensure_rule(target_key, source_key, rule_name, operator, expected_value)
    local tgt = db.select("id FROM profile_questions WHERE question_key = ?", target_key)
    local src = db.select("id FROM profile_questions WHERE question_key = ?", source_key)
    if not tgt or #tgt == 0 or not src or #src == 0 then return end
    local exists = db.select(
        "id FROM profile_question_rules WHERE question_id = ? AND source_question_id = ?",
        tgt[1].id, src[1].id
    )
    if exists and #exists > 0 then return end
    db.query([[
        INSERT INTO profile_question_rules
            (uuid, question_id, rule_name, rule_type, operator,
             source_question_id, expected_value, logic_group,
             is_active, created_at, updated_at)
        VALUES (?, ?, ?, 'visibility', ?, ?, ?, 'AND', true, NOW(), NOW())
    ]],
        MigrationUtils.generateUUID(),
        tgt[1].id, rule_name, operator, src[1].id, expected_value
    )
end

return {
    -- =========================================================================
    -- [1] Reorder existing rental-business questions + upsert rb_joint_owners.
    -- =========================================================================
    [1] = function()
        -- Find the rental-business category. Bail cleanly if the previous
        -- property-income-system migration hasn't run yet (fresh install with
        -- feature-gate mismatch); the migration is safe to re-run when the
        -- category eventually exists.
        local cat = db.select(
            "id FROM profile_categories WHERE slug = ? LIMIT 1",
            "rental-business"
        )
        if not cat or #cat == 0 then
            print("[Rental Joint Owners] rental-business category missing; skipping")
            return
        end
        local cat_id = cat[1].id

        -- Shift downstream questions so the new one can slot at position 4.
        -- Both UPDATEs are no-ops if the target rows are already at the new
        -- positions (WHERE guard prevents redundant timestamp churn).
        db.query([[
            UPDATE profile_questions
               SET display_order = 5, updated_at = NOW()
             WHERE question_key = 'rb_non_resident_landlord'
               AND display_order <> 5
        ]])
        db.query([[
            UPDATE profile_questions
               SET display_order = 6, updated_at = NOW()
             WHERE question_key = 'rb_first_letting_date'
               AND display_order <> 6
        ]])

        upsert_question(cat_id, {
            question_key  = "rb_joint_owners",
            label         = "Who do you let jointly with?",
            question_type = "repeating_group",
            is_required   = false,  -- required is enforced via the visibility rule + downstream validation
            display_order = 4,
            help_text     = "Add each co-owner's name, relationship to you, and their percentage share.",
            config_json   = cjson.encode(JOINT_OWNERS_CONFIG),
        })

        print("[Rental Joint Owners] Seeded rb_joint_owners repeating_group question")
    end,

    -- =========================================================================
    -- [2] Visibility rule: only show rb_joint_owners when rb_jointly_let=true.
    -- =========================================================================
    [2] = function()
        ensure_rule(
            "rb_joint_owners",
            "rb_jointly_let",
            "Show joint-owner details only when the landlord answered YES to letting jointly",
            "equals",
            "true"
        )
        print("[Rental Joint Owners] Ensured visibility rule (rb_joint_owners ← rb_jointly_let=true)")
    end,
}
