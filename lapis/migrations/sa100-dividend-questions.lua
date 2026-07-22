--[[
  SA100 Dividends & Interest — the 7 boxes on the SA100 income section
  ("Dividends and interest from UK banks and building societies") wired
  through the Dynamic Profile Builder so admins can rename, reorder,
  disable, add rules, or add entirely new boxes for other regions
  WITHOUT a code deploy.

  Why the profile builder and not a purpose-built table like
  business_line_categories / pension_payment_categories?
    - Admin wanted region-swappable question sets (US 1040 someday, etc.)
      and conditional visibility rules. Both are already first-class in
      the profile builder (namespace_id + profile_question_rules); the
      per-form line-category tables would need us to rebuild them.
    - The tradeoff we accept: SA100 box mapping lives in each question's
      `config_json.hmrc_mapping` (`{"form":"SA100","box":"1"}`) rather
      than a native column. The eventual filing worker reads that JSON.
    - Category `context='dividends'` mirrors the property / business /
      overseas_property contexts already in production. It's excluded
      from the classic /profile questionnaire (see profile-builder.lua
      schema endpoint) so onboarding stays focused.

  Answer scoping — one set of 7 answers PER USER PER TAX YEAR.
    - Category is created with `answer_scope='year'` (see migration
      dynamic-answer-scope.lua for the model). The /schema + /answers
      endpoints read the scope from the DB and route storage via the
      `user_profile_answers.tax_year` column. The partial unique
      index `idx_upa_user_question_year` guarantees one answer per
      (user, question, tax_year).
    - Frontend passes `?tax_year=YYYY-YY` on the /schema call and
      persists on /answers — no auto-created entity, no extra route.

  Idempotent: keyed on category.slug + question.question_key; re-running
  the migration updates labels / help / order but never duplicates. An
  admin edit to a seeded question is preserved by ON CONFLICT DO NOTHING
  on the inserts and by not touching admin-only columns (is_active,
  is_archived, config_json when it holds admin data).

  Only executed when PROJECT_CODE includes 'tax_copilot'.
]]

local db = require("lapis.db")
local cjson = require("cjson")
local MigrationUtils = require "helper.migration-utils"

-- The 7 SA100 dividend & interest boxes, in the order they appear on
-- the paper form. Values live in `config_json` because that's how the
-- profile builder carries arbitrary per-question metadata.
--
-- Copy is admin-editable — this is just the seed. Rename freely in
-- /admin/income-sources/dividends.
local SEED_QUESTIONS = {
    {
        key = "sa100_taxed_uk_interest",
        label = "Taxed UK interest — the net amount after tax has been taken off",
        help = "The amount your bank or building society paid you after they took basic-rate tax off.",
        order = 10,
        sa100_box = "1",
    },
    {
        key = "sa100_untaxed_uk_interest",
        label = "Untaxed UK interest — amounts which have not had tax taken off",
        help = "Interest paid gross (no tax deducted at source) — most bank interest since April 2016.",
        order = 20,
        sa100_box = "2",
    },
    {
        key = "sa100_untaxed_foreign_interest",
        label = "Untaxed foreign interest (up to £2,000)",
        help = "Foreign bank interest, if the total is £2,000 or less. Amounts above go on the Foreign pages instead.",
        order = 30,
        sa100_box = "3",
    },
    {
        key = "sa100_dividends_uk_companies",
        label = "Dividends from UK companies — the amount received",
        help = "The dividend amount your dividend voucher shows, before tax.",
        order = 40,
        sa100_box = "4",
    },
    {
        key = "sa100_other_dividends",
        label = "Other dividends — the amount received",
        help = "Authorised unit trusts, open-ended investment companies, some collective investments.",
        order = 50,
        sa100_box = "5",
    },
    {
        key = "sa100_foreign_dividends",
        label = "Foreign dividends (up to £500)",
        help = "Sterling equivalent, after foreign tax was taken off. If the total exceeds £500 include it on the Foreign pages instead of here.",
        order = 60,
        sa100_box = "6",
    },
    {
        key = "sa100_tax_off_foreign_dividends",
        label = "Tax taken off foreign dividends — the sterling equivalent",
        help = "The foreign tax withheld from your dividends, in £. Paired with box 6 for Foreign Tax Credit Relief.",
        order = 70,
        sa100_box = "7",
    },
}

-- Encode `config_json` for a currency question with its SA100 box
-- mapping. Downstream: /admin/income-sources reads this to show the
-- HMRC box badge; the eventual SA100 filing worker will read it too.
local function config_json_for(sa100_box)
    return cjson.encode({
        hmrc_mapping = { form = "SA100", box = sa100_box },
        -- UI hint for the frontend renderer — currency questions display
        -- a £ prefix and 2 decimal places by default; keep the hint here
        -- so admins editing the type later see the intent.
        input = { currency = "GBP", scale = 2 },
    })
end

return {
    -- =========================================================================
    -- 1. Seed the "Dividends and interest" category.
    --    Idempotent on slug; admin can rename freely via the admin UI.
    -- =========================================================================
    [1] = function()
        local slug = "dividends-and-interest"
        local existing = db.select(
            "id FROM profile_categories WHERE slug = ? LIMIT 1", slug
        )
        if #existing == 0 then
            -- answer_scope='year' is the new DB-driven mechanism (see
            -- migration dynamic-answer-scope.lua). Answers land in
            -- user_profile_answers with the tax_year column populated;
            -- one row per (user, question, tax_year). The `context`
            -- column stays as the string the frontend passes on
            -- /schema?context=dividends — it's the DISCOVERY key, not
            -- the scoping mechanism anymore.
            db.query([[
                INSERT INTO profile_categories
                    (uuid, name, slug, description, icon, display_order,
                     is_active, context, answer_scope, created_at, updated_at)
                VALUES (?, ?, ?, ?, ?, ?, TRUE, ?, 'year', NOW(), NOW())
            ]],
                MigrationUtils.generateUUID(),
                "Dividends and interest",
                slug,
                "SA100 income section: dividends and interest from UK banks and building societies. One set of answers per tax year.",
                "pound-sign",
                100,
                "dividends"
            )
            print("[SA100 Dividends] Created profile category '" .. slug .. "'")
        end
    end,

    -- =========================================================================
    -- 1b. Self-healing: force `answer_scope='year'` on the dividends
    --     category if it exists but isn't year-scoped.
    --
    --     History: an early revision of step [1] inserted the row
    --     WITHOUT the `answer_scope` column, so environments that ran
    --     that revision have the row with the DEFAULT 'user' and
    --     wouldn't see the SA100 boxes render (the /schema endpoint
    --     would 400 because dividends is supposed to be year-scoped).
    --     Because migrations don't re-run, the original step [1] can't
    --     fix pre-existing rows — this step does, idempotently.
    --
    --     Safe to run every time: WHERE answer_scope != 'year' means
    --     an admin who intentionally changed it back to 'user' via the
    --     admin UI wouldn't be surprised — but that would break the
    --     dividends page, and this migration exists precisely to
    --     restore the invariant that the seeded row is year-scoped.
    -- =========================================================================
    [2] = function()
        db.query([[
            UPDATE profile_categories
            SET answer_scope = 'year', updated_at = NOW()
            WHERE slug = 'dividends-and-interest'
              AND answer_scope <> 'year'
        ]])
    end,

    -- =========================================================================
    -- 3. Seed the 7 SA100 questions under the category.
    --    Idempotent on question_key; skip if the admin has already
    --    edited (we only ever INSERT, never UPDATE seed rows).
    -- =========================================================================
    [3] = function()
        local cat = db.select(
            "id FROM profile_categories WHERE slug = ? LIMIT 1",
            "dividends-and-interest"
        )
        if #cat == 0 then
            -- Category seed failed / was rolled back — bail rather than
            -- orphan questions.
            return
        end
        local category_id = cat[1].id

        for _, q in ipairs(SEED_QUESTIONS) do
            local existing = db.select(
                "id FROM profile_questions WHERE question_key = ? LIMIT 1",
                q.key
            )
            if #existing == 0 then
                db.query([[
                    INSERT INTO profile_questions
                        (uuid, category_id, question_key, label, help_text,
                         question_type, is_required, is_multi_value,
                         is_editable_by_user, display_order, config_json,
                         is_active, is_archived, created_at, updated_at)
                    VALUES (?, ?, ?, ?, ?, ?, FALSE, FALSE, TRUE, ?, ?::jsonb,
                            TRUE, FALSE, NOW(), NOW())
                ]],
                    MigrationUtils.generateUUID(),
                    category_id,
                    q.key,
                    q.label,
                    q.help,
                    "currency",
                    q.order,
                    config_json_for(q.sa100_box)
                )
            end
        end
        print("[SA100 Dividends] Seeded 7 SA100 dividend + interest questions")
    end,
}
