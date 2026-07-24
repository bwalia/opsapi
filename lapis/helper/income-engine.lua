--[[
  Income-engine feature-flag helper.

  Backend companion to the frontend helper at
  frontend/src/lib/income-engine.ts in the diy-tax-return-uk repo.
  Reads which engine a given income type is served by in the current
  env, and whether writes should be forked to the OTHER engine during
  a migration window.

  See docs/PROFILE_BUILDER_UNIFICATION_PLAN.md §4 in the diy-tax-return-uk
  repo for the full flag surface and per-env rollout schedule.

  Env-var convention:
    INCOME_ENGINE_<UPPER_INCOME_TYPE_KEY>              = "profile_builder"
                                                       (else "form_sections",
                                                        the default)
    INCOME_ENGINE_<UPPER_INCOME_TYPE_KEY>_DUAL_WRITE   = "true" or "1"
                                                       (else false)

  Same names as the frontend WITHOUT the NEXT_PUBLIC_ prefix, so the
  Helm chart injects them into both pods per env with a single source
  string in values.yaml.

  Defaults are the current-behaviour engine ("form_sections") + no dual
  write. Any income type not explicitly configured stays on the legacy
  path — the rollout is opt-in per type per env, never accidental.

  Kept intentionally tiny + dependency-free so it can be required from
  any route/query without pulling in DB or ORM layers. Runtime evaluation
  every call (no cache) — env changes in a pod's env are picked up at
  restart, not process boot; if we ever memoize this we must invalidate
  on SIGHUP.
]]

local M = {}

local FORM_SECTIONS = "form_sections"
local PROFILE_BUILDER = "profile_builder"

M.FORM_SECTIONS = FORM_SECTIONS
M.PROFILE_BUILDER = PROFILE_BUILDER

--- Returns the engine that should serve the given income type key in
--- this env. Falls back to "form_sections" (current-behaviour default)
--- for missing / empty / unknown values — a new income type never
--- accidentally opts into the unfinished engine.
--- @param income_type_key string  e.g. "salary", "pension_payments"
--- @return string                 "form_sections" | "profile_builder"
function M.mode(income_type_key)
    if type(income_type_key) ~= "string" or income_type_key == "" then
        return FORM_SECTIONS
    end
    local env_name = "INCOME_ENGINE_" .. income_type_key:upper()
    local val = os.getenv(env_name)
    if val == PROFILE_BUILDER then return PROFILE_BUILDER end
    return FORM_SECTIONS
end

--- Should writes be forked to the non-primary store for this income
--- type? On during migration windows for rollback safety, off in
--- steady state. Env var (per type):
---   INCOME_ENGINE_<UPPER>_DUAL_WRITE=true
--- @param income_type_key string
--- @return boolean
function M.dual_write_enabled(income_type_key)
    if type(income_type_key) ~= "string" or income_type_key == "" then
        return false
    end
    local env_name = "INCOME_ENGINE_" .. income_type_key:upper() .. "_DUAL_WRITE"
    local val = os.getenv(env_name)
    return val == "true" or val == "1"
end

--- Convenience predicate — reads more naturally at call sites than a
--- string-equality comparison on M.mode(...).
--- @param income_type_key string
--- @return boolean
function M.uses_profile_builder(income_type_key)
    return M.mode(income_type_key) == PROFILE_BUILDER
end

return M
