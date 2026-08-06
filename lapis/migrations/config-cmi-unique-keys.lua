--[[
  Config-as-Code (CMI) — Backfill UNIQUE indexes on composite business keys.

  Prep step for `lapis config export|import`. The export/import CLI upserts
  rows using their stable business key as the identity — that only works if
  the DB enforces uniqueness on the key we're upserting on.

  Every table in scope already has `id` (serial) and `uuid` (unique) plus a
  stable business-key column. Four tables use a COMPOSITE key that isn't
  yet backed by a unique index:

    property_line_categories : (kind, category_key)
    business_line_categories : (kind, category_key)
    profile_question_options : (question_id, value)
    profile_lookup_values    : (lookup_table_id, value)

  Adding them here is safe:
    - Every statement is CREATE UNIQUE INDEX IF NOT EXISTS — idempotent, no
      dupes across re-runs.
    - The seeded data in each table is already unique on these columns
      (verified against int on 2026-08-06). If acc/prod happens to hold a
      dup we didn't spot, the index build will error loudly — that IS the
      desired outcome; fix the dup once, re-run, done.

  These are structural indexes only. No column adds, no data changes.
  Everything else the CMI CLI needs is already in the schema.
]]

local db = require("lapis.db")

return {
    -- =========================================================================
    -- 1. property_line_categories : (kind, category_key)
    -- =========================================================================
    [1] = function()
        db.query([[
            CREATE UNIQUE INDEX IF NOT EXISTS uq_plc_kind_key
            ON property_line_categories (kind, category_key)
        ]])
        print("[CMI] Ensured uq_plc_kind_key on property_line_categories")
    end,

    -- =========================================================================
    -- 2. business_line_categories : (kind, category_key)
    -- =========================================================================
    [2] = function()
        db.query([[
            CREATE UNIQUE INDEX IF NOT EXISTS uq_blc_kind_key
            ON business_line_categories (kind, category_key)
        ]])
        print("[CMI] Ensured uq_blc_kind_key on business_line_categories")
    end,

    -- =========================================================================
    -- 3. profile_question_options : (question_id, value)
    -- =========================================================================
    [3] = function()
        db.query([[
            CREATE UNIQUE INDEX IF NOT EXISTS uq_pqo_q_value
            ON profile_question_options (question_id, value)
        ]])
        print("[CMI] Ensured uq_pqo_q_value on profile_question_options")
    end,

    -- =========================================================================
    -- 4. profile_lookup_values : (lookup_table_id, value)
    -- =========================================================================
    [4] = function()
        db.query([[
            CREATE UNIQUE INDEX IF NOT EXISTS uq_plv_t_value
            ON profile_lookup_values (lookup_table_id, value)
        ]])
        print("[CMI] Ensured uq_plv_t_value on profile_lookup_values")
    end,
}
