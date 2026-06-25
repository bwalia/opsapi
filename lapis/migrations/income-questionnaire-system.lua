--[[
  Income Questionnaire — per-user income-source selection.

  Captures the onboarding/tax-return answer "do you have income sources?" plus
  the multi-select list of income types the user picked from the income_types
  catalogue (migrations/income-types-system.lua).

  Storage:
    - tax_user_profiles.has_income_sources : BOOLEAN (NULL = not answered yet,
      TRUE = yes, FALSE = no). Mirrors how default_profile_key (migration 75)
      was added to the same table.
    - tax_user_income_types : one row per (user, income_type_key) the user
      selected. Saved with replace-the-whole-set semantics by
      queries/IncomeSelectionQueries.lua. The key is a plain varchar (no FK) so
      retiring a catalogue type leaves a user's historical selection intact —
      same rationale as my_incomes.income_type.

  Phase 4 (sectioned My Income) + FastAPI read the selection to decide which
  income sections to show / aggregate.
]]

local schema = require("lapis.db.schema")
local types = schema.types
local db = require("lapis.db")

return {
    -- 1. has_income_sources flag on tax_user_profiles
    [1] = function()
        db.query([[
            ALTER TABLE tax_user_profiles
            ADD COLUMN IF NOT EXISTS has_income_sources BOOLEAN DEFAULT NULL
        ]])
        print("[Income Questionnaire] Added has_income_sources to tax_user_profiles")
    end,

    -- 2. tax_user_income_types selection table + indexes
    [2] = function()
        schema.create_table("tax_user_income_types", {
            { "id",              types.serial },
            { "uuid",            types.varchar({ unique = true }) },
            { "user_id",         types.integer },
            { "namespace_id",    types.integer({ null = true }) },
            { "income_type_key", types.varchar }, -- catalogue key (no FK by design)
            { "created_at",      types.time({ default = db.raw("NOW()") }) },
            { "updated_at",      types.time({ default = db.raw("NOW()") }) },
            "PRIMARY KEY (id)"
        })
        -- One row per (user, type); the UNIQUE index also guards the
        -- replace-the-set save against accidental duplicates.
        schema.create_index("tax_user_income_types", "user_id", "income_type_key", { unique = true })
        schema.create_index("tax_user_income_types", "user_id")
        schema.create_index("tax_user_income_types", "income_type_key")
        print("[Income Questionnaire] Created tax_user_income_types table")
    end,
}
