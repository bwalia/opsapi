--[[
  answer_scope = 'entity_year' — one answer per user, per entity, per tax year.

  Until now an entity-scoped answer (a job's expenses, an overseas holding's
  capital allowances) had no tax year: the same figure applied to every
  year, so it couldn't be put on one year's return. Categories switched to
  'entity_year' store answers with BOTH entity_uuid and tax_year.

  Existing year-less entity answers are kept untouched; the /schema endpoint
  serves them as the fallback for any year until that year's answer is saved.

  1. Allow the new value in chk_pc_answer_scope.
  2. Narrow idx_upa_user_question_entity to year-less entity rows (every
     existing entity row is year-less — the API rejected entity + tax_year).
  3. Unique (user, question, entity, tax_year) for entity-year rows.
]]

local db = require("lapis.db")

return {
    [1] = function()
        db.query("ALTER TABLE profile_categories DROP CONSTRAINT IF EXISTS chk_pc_answer_scope")
        db.query([[
            ALTER TABLE profile_categories
            ADD CONSTRAINT chk_pc_answer_scope
            CHECK (answer_scope IN ('user', 'entity', 'year', 'entity_year'))
        ]])
        print("[Answer Scope] chk_pc_answer_scope now allows 'entity_year'")
    end,

    [2] = function()
        db.query("DROP INDEX IF EXISTS idx_upa_user_question_entity")
        db.query([[
            CREATE UNIQUE INDEX IF NOT EXISTS idx_upa_user_question_entity
            ON user_profile_answers (user_id, question_id, entity_uuid)
            WHERE entity_uuid IS NOT NULL AND tax_year IS NULL
        ]])
        db.query([[
            CREATE UNIQUE INDEX IF NOT EXISTS idx_upa_user_question_entity_year
            ON user_profile_answers (user_id, question_id, entity_uuid, tax_year)
            WHERE entity_uuid IS NOT NULL AND tax_year IS NOT NULL
        ]])
        print("[Answer Scope] Added per-entity-per-year unique index on user_profile_answers")
    end,
}
