--[[
    Forms limits per workspace plan (namespaces.plan: free | starter |
    professional | enterprise). nil = unlimited. Only platform admins / billing
    change a workspace's plan, so owners can't lift their own limits.

    For now (decided 2026-10-09) everything is free and every form shows
    "Powered by OpsAPI": no plan has limits, and none may hide the branding.
    Pricing later = filling in PLANS (forms, responses_per_month,
    hide_branding = true for the plans that may hide it).
]]

local db = require("lapis.db")

local Limits = {}

Limits.PLANS = {
    free = {},
    starter = {},
    professional = {},
    enterprise = {},
}

local DEFAULTS = { hide_branding = false }

--- The limits of a workspace. @return { forms?, responses_per_month?, hide_branding }
function Limits.of(namespace_id)
    local ns = db.query("SELECT plan FROM namespaces WHERE id = ?", namespace_id)[1]
    local plan = Limits.PLANS[ns and ns.plan or "free"] or {}
    local out = {}
    for k, v in pairs(DEFAULTS) do out[k] = v end
    for k, v in pairs(plan) do out[k] = v end
    return out
end

--- Has the workspace used this month's responses? (only counted when limited)
function Limits.month_full(namespace_id)
    local max = Limits.of(namespace_id).responses_per_month
    if not max then return false end
    local n = tonumber(db.query([[SELECT COUNT(*) AS n FROM form_submissions WHERE namespace_id = ?
        AND status <> 'spam' AND created_at >= date_trunc('month', NOW())]], namespace_id)[1].n)
    return n >= max, max
end

return Limits
