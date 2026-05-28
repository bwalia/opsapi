--[[
    Entitlement Service
    ===================

    Computes what a user can do RIGHT NOW, from their active subscription and
    the plan's `features` JSON. Fresh on every call (no caching) — Stripe,
    mirrored via webhooks, is the source of truth. No active subscription =>
    free-tier defaults.

    Snapshot shape:
      {
        has_subscription   = boolean,
        status             = 'active'|'trialing'|'past_due'|'none',
        plan               = { uuid, name, plan_type } | nil,
        current_period_end = timestamp | nil,
        cancel_at_period_end = boolean,
        features           = { ... }      -- the plan's entitlement map
      }
]]

local BillingSubscriptionQueries = require("queries.BillingSubscriptionQueries")
local BillingPlanQueries = require("queries.BillingPlanQueries")
local cjson = require("cjson")

local EntitlementService = {}

-- Baseline when the user has no active subscription. Kept empty (no paid
-- features) so callers treat "missing" as free-tier; seed a 'free' plan later
-- if you want explicit free limits.
local FREE_FEATURES = {}

local function decode_features(plan)
    if not plan then return {} end
    local f = plan.features
    if type(f) == "string" then
        local ok, decoded = pcall(cjson.decode, f)
        return (ok and type(decoded) == "table") and decoded or {}
    end
    if type(f) == "table" then return f end
    return {}
end

local function truthy(v)
    return v == true or v == "t" or v == "true" or v == 1
end

-- Full entitlement snapshot for a user within a namespace.
function EntitlementService.forUser(namespace_id, user_uuid)
    local sub = BillingSubscriptionQueries.getActiveForUser(namespace_id, user_uuid)
    if not sub then
        return {
            has_subscription = false,
            status = "none",
            plan = nil,
            current_period_end = nil,
            cancel_at_period_end = false,
            features = FREE_FEATURES,
        }
    end

    local plan = sub.plan_id and BillingPlanQueries.getById(sub.plan_id) or nil
    return {
        has_subscription = true,
        status = sub.status,
        plan = plan and { uuid = plan.uuid, name = plan.name, plan_type = plan.plan_type } or nil,
        current_period_end = sub.current_period_end,
        cancel_at_period_end = truthy(sub.cancel_at_period_end),
        features = decode_features(plan),
    }
end

-- Convenience: does the user's plan grant a boolean feature (e.g. file_to_hmrc)?
function EntitlementService.can(namespace_id, user_uuid, feature_key)
    local snap = EntitlementService.forUser(namespace_id, user_uuid)
    return truthy(snap.features[feature_key])
end

-- Convenience: numeric limit for a feature (nil = unlimited / not set).
function EntitlementService.limit(namespace_id, user_uuid, feature_key)
    local snap = EntitlementService.forUser(namespace_id, user_uuid)
    return tonumber(snap.features[feature_key])
end

return EntitlementService
