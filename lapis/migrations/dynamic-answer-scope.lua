--[[
  Dynamic answer scope — move the "how are these answers scoped?" decision
  out of code (`PER_ENTITY_CONTEXTS` in routes/profile-builder.lua) and
  into the database, so admins can define brand-new form sections — SA100
  income boxes today, US 1040 or a future SA101/106 section tomorrow —
  without a single code deploy.

  Three modes cover today's needs and the near-term roadmap:

    answer_scope = 'user'   → one answer per user
                              (classic /profile questions, rental_business)
    answer_scope = 'entity' → one answer per user per entity
                              (per property / business / holding)
                              `entity_type` picks WHICH kind of entity.
    answer_scope = 'year'   → one answer per user per tax year
                              (SA100 dividends / interest / savings /
                               capital gains — every income section that
                               changes annually)

  If we ever need a fourth mode (e.g. per-entity per-year rental returns),
  it's one CHECK-constraint update + one branch in the endpoint — not a
  redesign.

  Storage on `user_profile_answers`:
    - user   → entity_uuid IS NULL, tax_year IS NULL
    - entity → entity_uuid IS NOT NULL, tax_year IS NULL
    - year   → entity_uuid IS NULL, tax_year IS NOT NULL

  Three partial unique indexes enforce one answer per (user, question) in
  each mode. The existing two indexes stay; step [4] adds the third for
  year scope. Old code paths that never touch `tax_year` see zero
  behaviour change — the new index is invisible to them.

  Rollout safety:
    - Migration is BACKWARD-COMPATIBLE. The old backend keeps working
      because its hardcoded PER_ENTITY_CONTEXTS map matches what the
      backfill puts on existing rows. New backend reads the columns.
    - Rolling deploys are safe: both versions of the backend can serve
      simultaneously against the migrated schema.

  Only executed when PROJECT_CODE includes 'tax_copilot' (matches the
  profile-builder feature flag — no point in the columns without the
  profile builder).
]]

local db = require("lapis.db")

return {
    -- =========================================================================
    -- 1. profile_categories.answer_scope
    --    Default 'user' preserves existing behaviour for every row that
    --    isn't per-entity or per-year.
    -- =========================================================================
    [1] = function()
        db.query([[
            ALTER TABLE profile_categories
            ADD COLUMN IF NOT EXISTS answer_scope varchar NOT NULL DEFAULT 'user'
        ]])
        -- CHECK in its own statement so re-running the migration doesn't
        -- fail on "constraint already exists"; pcall + IF NOT EXISTS
        -- equivalent by name.
        pcall(function()
            db.query([[
                ALTER TABLE profile_categories
                ADD CONSTRAINT chk_pc_answer_scope
                CHECK (answer_scope IN ('user', 'entity', 'year'))
            ]])
        end)
        db.query("CREATE INDEX IF NOT EXISTS idx_pc_answer_scope ON profile_categories (answer_scope)")
        print("[Answer Scope] Added answer_scope column to profile_categories")
    end,

    -- =========================================================================
    -- 2. profile_categories.entity_type
    --    Required when answer_scope='entity' (checked in application code,
    --    not a table constraint — a CHECK across two columns fires on
    --    every row and would block backfill).
    -- =========================================================================
    [2] = function()
        db.query([[
            ALTER TABLE profile_categories
            ADD COLUMN IF NOT EXISTS entity_type varchar NULL
        ]])
        db.query("CREATE INDEX IF NOT EXISTS idx_pc_entity_type ON profile_categories (entity_type)")
        print("[Answer Scope] Added entity_type column to profile_categories")
    end,

    -- =========================================================================
    -- 3. user_profile_answers.tax_year
    --    VARCHAR(7) fits YYYY-YY (e.g. '2026-27'). Nullable — populated
    --    only by year-scoped answers; classic and per-entity answers
    --    leave it NULL.
    -- =========================================================================
    [3] = function()
        db.query([[
            ALTER TABLE user_profile_answers
            ADD COLUMN IF NOT EXISTS tax_year varchar(7) NULL
        ]])
        db.query([[
            CREATE INDEX IF NOT EXISTS idx_upa_tax_year
            ON user_profile_answers (tax_year)
            WHERE tax_year IS NOT NULL
        ]])
        print("[Answer Scope] Added tax_year column to user_profile_answers")
    end,

    -- =========================================================================
    -- 4. Partial unique index for year-scoped answers.
    --    Existing indexes (created in property-income-system.lua migrations)
    --    stay unchanged:
    --      idx_upa_user_question         → WHERE entity_uuid IS NULL
    --      idx_upa_user_question_entity  → WHERE entity_uuid IS NOT NULL
    --    But `idx_upa_user_question` matches BOTH classic AND year rows
    --    (year rows also have entity_uuid IS NULL) — a user answering the
    --    same question in two different tax years would collide.
    --
    --    We can't drop that index without breaking classic answers, and
    --    Postgres doesn't allow OVERLAPPING partial unique indexes on the
    --    same key. The clean fix is to make the classic index MORE
    --    restrictive (add tax_year IS NULL) and add a separate year
    --    index. That's what these three statements do, in order:
    --      a) drop the existing user_question index
    --      b) recreate it with tax_year IS NULL guard
    --      c) create the year-scope unique index
    --    Safe because we're inside a migration transaction (Lapis
    --    wraps each step) — an interrupted run leaves the schema
    --    consistent.
    -- =========================================================================
    [4] = function()
        db.query("DROP INDEX IF EXISTS idx_upa_user_question")
        db.query([[
            CREATE UNIQUE INDEX IF NOT EXISTS idx_upa_user_question
            ON user_profile_answers (user_id, question_id)
            WHERE entity_uuid IS NULL AND tax_year IS NULL
        ]])
        db.query([[
            CREATE UNIQUE INDEX IF NOT EXISTS idx_upa_user_question_year
            ON user_profile_answers (user_id, question_id, tax_year)
            WHERE entity_uuid IS NULL AND tax_year IS NOT NULL
        ]])
        print("[Answer Scope] Added year-scope partial unique index on user_profile_answers")
    end,

    -- =========================================================================
    -- 5. Backfill existing categories.
    --    Today's hardcoded map:
    --      PER_ENTITY_CONTEXTS = {
    --        property          = 'property',
    --        business          = 'business',
    --        overseas_property = 'overseas_property',
    --      }
    --    Every other context (including NULL and 'rental_business')
    --    already defaults to answer_scope='user' — no update needed.
    --    Idempotent: re-running the update just re-writes the same value.
    -- =========================================================================
    [5] = function()
        db.query([[
            UPDATE profile_categories
            SET answer_scope = 'entity', entity_type = 'property'
            WHERE context = 'property' AND (answer_scope IS NULL OR answer_scope = 'user')
        ]])
        db.query([[
            UPDATE profile_categories
            SET answer_scope = 'entity', entity_type = 'business'
            WHERE context = 'business' AND (answer_scope IS NULL OR answer_scope = 'user')
        ]])
        db.query([[
            UPDATE profile_categories
            SET answer_scope = 'entity', entity_type = 'overseas_property'
            WHERE context = 'overseas_property' AND (answer_scope IS NULL OR answer_scope = 'user')
        ]])
        print("[Answer Scope] Backfilled answer_scope/entity_type on existing categories")
    end,
}
