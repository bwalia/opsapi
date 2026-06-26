--[[
  Income Questionnaire — cleanup of the bespoke implementation.

  The first income-questionnaire attempt (migrations 720/721) added a
  has_income_sources column to tax_user_profiles and a tax_user_income_types
  selection table. That bespoke storage is replaced by the dynamic Profile
  Builder: a `has_income_sources` boolean question + a `selected_income_types`
  multi_select question (seeded in dynamic-profile-builder.lua migration [38]),
  with answers living in user_profile_answers.

  This drops the now-unused bespoke schema. Idempotent (IF EXISTS) so it's safe
  on environments that never ran 720/721.
]]

local db = require("lapis.db")

return {
    [1] = function()
        db.query("DROP TABLE IF EXISTS tax_user_income_types")
        db.query("ALTER TABLE tax_user_profiles DROP COLUMN IF EXISTS has_income_sources")
        print("[Income Questionnaire] Dropped bespoke tax_user_income_types + has_income_sources")
    end,
}
