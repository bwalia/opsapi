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

-- ===========================================================================
-- Apps (Billing & Entitlements, docs/BILLING_ENTITLEMENTS.md §5)
-- ===========================================================================
-- A customer's effective features for an app = the app's default plan, then
-- the newest entitling subscription, then active grants, combined per
-- feature: on/off features are ON if any source turns them on; limits take
-- the largest value, and null (unlimited) beats any number. Only features in
-- the app's catalogue are returned, each with a value (off / 0 when no source
-- sets it). A few indexed queries, no Stripe calls.

local db = require("lapis.db")
local NULL = cjson.null

--- Combine `values` into `out` for every catalogue feature (see above).
function EntitlementService.merge(out, catalog, values)
    if type(values) ~= "table" then return out end
    for key, ftype in pairs(catalog) do
        local v = values[key]
        if v ~= nil then
            if ftype == "boolean" then
                out[key] = out[key] == true or v == true
            elseif out[key] == NULL or v == NULL then
                out[key] = NULL
            else
                out[key] = math.max(tonumber(out[key]) or 0, tonumber(v) or 0)
            end
        end
    end
    return out
end

local function plan_ref(row)
    if not row or not row.plan_uuid then return nil end
    return { uuid = row.plan_uuid, key = row.plan_key, name = row.plan_name }
end

--- Resolve what `customer` may use in `app` right now.
-- @param app full billing_apps row; customer = customers row ({ id, uuid, external_id })
-- @return { plan, status, features, sources, expires_at (unix), policy, grace_seconds }
function EntitlementService.resolve(app, customer)
    local catalog, features = {}, {}
    for _, r in ipairs(db.query("SELECT key, type FROM billing_features WHERE app_id = ?", app.id)) do
        catalog[r.key] = r.type
        if r.type == "boolean" then features[r.key] = false else features[r.key] = 0 end
    end
    local sources, plan, status = {}, nil, "none"
    local now = ngx.time()
    local expires_at = now + (tonumber(app.entitlement_ttl_seconds) or 900)
    local function until_(epoch)
        epoch = tonumber(epoch)
        if epoch and epoch > now and epoch < expires_at then expires_at = epoch end
    end

    local default = db.query([[
        SELECT uuid AS plan_uuid, plan_key, name AS plan_name, features FROM billing_plans
        WHERE app_id = ? AND is_default AND active AND deleted_at IS NULL LIMIT 1]], app.id)[1]
    if default then
        EntitlementService.merge(features, catalog, default.features)
        plan, status = plan_ref(default), "free"
        sources[#sources + 1] = { type = "default_plan", plan = plan_ref(default) }
    end

    -- Plans keep entitling their existing subscribers and grantees after a
    -- soft delete (grandfathered): no deleted_at filter on the joins below.
    local sub = db.query([[
        SELECT s.uuid, s.status, extract(epoch FROM s.current_period_end)::bigint AS period_end,
               p.uuid AS plan_uuid, p.plan_key, p.name AS plan_name, p.features
        FROM billing_subscriptions s LEFT JOIN billing_plans p ON p.id = s.plan_id
        WHERE s.app_id = ? AND s.customer_id = ?
          AND (s.status IN ('active', 'trialing')
               OR (s.status = 'past_due' AND (s.current_period_end IS NULL
                   OR s.current_period_end + make_interval(days => ?) > (NOW() AT TIME ZONE 'UTC'))))
        ORDER BY s.created_at DESC LIMIT 1]], app.id, customer.id, tonumber(app.past_due_grace_days) or 7)[1]
    if sub then
        EntitlementService.merge(features, catalog, sub.features)
        plan, status = plan_ref(sub) or plan, sub.status
        until_(sub.period_end)
        sources[#sources + 1] = { type = "subscription", uuid = sub.uuid, status = sub.status, plan = plan_ref(sub) }
    end

    local grants = db.query([[
        SELECT g.uuid, g.features AS grant_features, extract(epoch FROM g.expires_at)::bigint AS expires,
               p.uuid AS plan_uuid, p.plan_key, p.name AS plan_name, p.features AS plan_features
        FROM billing_grants g LEFT JOIN billing_plans p ON p.id = g.plan_id
        WHERE g.app_id = ? AND g.customer_id = ? AND g.revoked_at IS NULL AND g.starts_at <= NOW()
          AND (g.expires_at IS NULL OR g.expires_at > NOW())
        ORDER BY (g.plan_id IS NULL), g.created_at DESC]], app.id, customer.id)
    for _, g in ipairs(grants) do
        EntitlementService.merge(features, catalog, g.plan_features)
        EntitlementService.merge(features, catalog, g.grant_features)
        if not sub and g.plan_uuid and status ~= "granted" then plan, status = plan_ref(g), "granted" end
        until_(g.expires)
        sources[#sources + 1] = { type = "grant", uuid = g.uuid, plan = plan_ref(g), expires_at = tonumber(g.expires) }
    end

    return {
        plan = plan,
        status = status,
        features = features,
        sources = sources,
        expires_at = expires_at,
        policy = app.offline_policy,
        grace_seconds = tonumber(app.offline_grace_seconds) or 0,
    }
end

--- Who signs: OPSAPI_PUBLIC_URL, else this request's origin.
function EntitlementService.issuer()
    local url = os.getenv("OPSAPI_PUBLIC_URL")
    if url and url ~= "" then return (url:gsub("/+$", "")) end
    return ngx.var.scheme .. "://" .. (ngx.var.http_host or ngx.var.host)
end

--- The signed entitlement token for a resolution (docs §6).
-- @return token | nil, "not configured"
function EntitlementService.token(app, customer, ent, namespace_uuid)
    return require("lib.billing-signing").sign("opsapi-entitlements+jwt", {
        iss = EntitlementService.issuer(),
        aud = app.uuid,
        sub = customer.external_id or customer.uuid,
        ns = namespace_uuid,
        plan = ent.plan and (ent.plan.key or ent.plan.uuid) or NULL,
        status = ent.status,
        features = ent.features,
        iat = ngx.time(),
        exp = ent.expires_at,
        grace = ent.grace_seconds,
        policy = ent.policy,
    })
end

return EntitlementService
