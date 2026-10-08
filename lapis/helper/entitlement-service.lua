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
-- Apps (Billing & Entitlements, docs/BILLING_ENTITLEMENTS.md §6)
-- ===========================================================================
-- What a customer may use in an app right now, from these sources:
--   1. the app's default plan (free for everyone)
--   2. the newest entitling recurring subscription: every feature of its plan
--   3. active one_time / fixed_term purchases: their plan's features released
--      on or before the purchase's updates_until (null = all)
--   4. active grants (a plan and/or feature values)
-- On/off features are on if any source turns them on; limits take the
-- largest value, null (unlimited) beating any number. Only catalogue features
-- are returned, each with a value (false / 0 when nothing sets it).
-- The answer's plan_key / status / access_until / updates_until come from the
-- deciding source: subscription > newest purchase > plan grant > default plan.

local db = require("lapis.db")
local Settings = require("lib.billing-settings")
local NULL = cjson.null

--- Combine `values` into `out` for every catalogue feature (see above).
-- catalog: { key = "boolean"|"limit" } or { key = { type, released } }.
-- updates_until (unix seconds, optional): skip features released after it.
function EntitlementService.merge(out, catalog, values, updates_until)
    if type(values) ~= "table" then return out end
    for key, spec in pairs(catalog) do
        local ftype, released = spec, nil
        if type(spec) == "table" then ftype, released = spec.type, spec.released end
        local v = values[key]
        if v ~= nil and not (updates_until and released and released > updates_until) then
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

local function epoch(v) local n = tonumber(v) return n and n > 0 and n or nil end

--- Resolve what `customer` may use in `app` (uncached; see get()).
-- @return { plan, status, features, sources, access_until, updates_until, expires_at }
function EntitlementService.resolve(app, customer)
    local settings = Settings.resolve(app)
    local catalog, features = {}, {}
    for _, r in ipairs(db.query([[SELECT key, type, extract(epoch FROM released_at)::bigint AS released
        FROM billing_features WHERE app_id = ?]], app.id)) do
        catalog[r.key] = { type = r.type, released = tonumber(r.released) }
        if r.type == "boolean" then features[r.key] = false else features[r.key] = 0 end
    end
    local now = ngx.time()
    local expires_at = now + settings.token_ttl_seconds
    local function until_(t)
        t = epoch(t)
        if t and t > now and t < expires_at then expires_at = t end
    end
    local sources, decided = {}, nil
    local function decide(rank, ref, status, access_until, updates_until)
        if not decided or rank < decided.rank then
            decided = { rank = rank, plan = ref, status = status, access_until = access_until,
                updates_until = updates_until }
        end
    end

    local default = db.query([[
        SELECT uuid AS plan_uuid, plan_key, name AS plan_name, features FROM billing_plans
        WHERE app_id = ? AND is_default AND active AND deleted_at IS NULL LIMIT 1]], app.id)[1]
    if default then
        EntitlementService.merge(features, catalog, default.features)
        decide(4, plan_ref(default), "free")
        sources[#sources + 1] = { type = "default_plan", plan = plan_ref(default) }
    end

    -- Plans keep entitling their existing buyers after a soft delete
    -- (grandfathered): no deleted_at filter on the joins below.
    local sub = customer.id and db.query([[
        SELECT s.uuid, s.status, s.cancel_at_period_end, s.source,
               extract(epoch FROM s.current_period_end)::bigint AS period_end,
               p.uuid AS plan_uuid, p.plan_key, p.name AS plan_name, p.features
        FROM billing_subscriptions s LEFT JOIN billing_plans p ON p.id = s.plan_id
        WHERE s.app_id = ? AND s.customer_id = ? AND ]] .. EntitlementService.liveSubscriptionSql("s") .. [[
        ORDER BY s.created_at DESC LIMIT 1]], app.id, customer.id, settings.past_due_grace_days)[1]
    if sub then
        EntitlementService.merge(features, catalog, sub.features)
        until_(sub.period_end)
        -- An auto-renewing subscription has no end date; one set to cancel does.
        local ends = (sub.cancel_at_period_end == true) and epoch(sub.period_end) or nil
        decide(1, plan_ref(sub), sub.status, ends, nil)
        sources[#sources + 1] = { type = "subscription", uuid = sub.uuid, status = sub.status, source = sub.source,
            plan = plan_ref(sub) }
    end

    local purchases = customer.id and db.query([[
        SELECT pu.uuid, pu.purchase_type, pu.source,
               extract(epoch FROM pu.access_until)::bigint AS access_until,
               extract(epoch FROM pu.updates_until)::bigint AS updates_until,
               p.uuid AS plan_uuid, p.plan_key, p.name AS plan_name, p.features
        FROM billing_purchases pu JOIN billing_plans p ON p.id = pu.plan_id
        WHERE pu.app_id = ? AND pu.customer_id = ? AND pu.status = 'active'
          AND (pu.access_until IS NULL OR pu.access_until > NOW())
        ORDER BY pu.created_at DESC]], app.id, customer.id) or {}
    for i, pu in ipairs(purchases) do
        EntitlementService.merge(features, catalog, pu.features, epoch(pu.updates_until))
        until_(pu.access_until)
        if i == 1 then decide(2, plan_ref(pu), "purchased", epoch(pu.access_until), epoch(pu.updates_until)) end
        sources[#sources + 1] = { type = "purchase", uuid = pu.uuid, purchase_type = pu.purchase_type,
            source = pu.source, plan = plan_ref(pu), access_until = epoch(pu.access_until),
            updates_until = epoch(pu.updates_until) }
    end

    local grants = customer.id and db.query([[
        SELECT g.uuid, g.features AS grant_features, extract(epoch FROM g.expires_at)::bigint AS expires,
               p.uuid AS plan_uuid, p.plan_key, p.name AS plan_name, p.features AS plan_features
        FROM billing_grants g LEFT JOIN billing_plans p ON p.id = g.plan_id
        WHERE g.app_id = ? AND g.customer_id = ? AND g.revoked_at IS NULL AND g.starts_at <= NOW()
          AND (g.expires_at IS NULL OR g.expires_at > NOW())
        ORDER BY (g.plan_id IS NULL), g.created_at DESC]], app.id, customer.id) or {}
    for _, g in ipairs(grants) do
        EntitlementService.merge(features, catalog, g.plan_features)
        EntitlementService.merge(features, catalog, g.grant_features)
        until_(g.expires)
        if g.plan_uuid then decide(3, plan_ref(g), "granted", epoch(g.expires), nil) end
        sources[#sources + 1] = { type = "grant", uuid = g.uuid, plan = plan_ref(g), expires_at = epoch(g.expires) }
    end

    decided = decided or { status = "none" }
    return {
        plan = decided.plan,
        status = decided.status,
        features = features,
        sources = sources,
        access_until = decided.access_until,
        updates_until = decided.updates_until,
        expires_at = expires_at,
        offline_policy = settings.offline_policy,
        grace_seconds = settings.grace_days * 86400,
    }
end

-- ---------------------------------------------------------------------------
-- Cache (docs §15): Redis, keyed by the app's cache generation so plan,
-- feature and settings changes retire every entry at once; customer-scoped
-- writes call bust(). Without Redis every call resolves from the database.
-- ---------------------------------------------------------------------------

local function cache_key(app, customer_id)
    return ("billing:ent:v1:%s:%s:%s"):format(app.id, app.cache_generation or 1, customer_id)
end

--- Resolution + signed token, cached until shortly before the token expires.
-- @return ent, token (token nil when signing isn't configured)
function EntitlementService.get(app, customer, namespace_uuid)
    local RedisClient = require("helper.redis-client")
    local key = customer.id and cache_key(app, customer.id)
    local red = key and RedisClient.connect()
    if red then
        local hit = red:get(key)
        RedisClient.release(red)
        local ok, v = pcall(cjson.decode, hit ~= ngx.null and hit or "")
        if ok and type(v) == "table" and v.ent then
            if type(v.ent.features) ~= "table" or v.ent.features[1] ~= nil then v.ent.features = {} end
            return v.ent, v.token ~= NULL and v.token or nil
        end
    end
    local ent = EntitlementService.resolve(app, customer)
    local token = EntitlementService.token(app, customer, ent)
    local ttl = ent.expires_at - ngx.time() - 30
    if key and ttl > 0 then
        red = RedisClient.connect()
        if red then
            red:set(key, require("lib.billing-signing").encode({ ent = ent, token = token or NULL }), "EX", ttl)
            RedisClient.release(red)
        end
    end
    return ent, token
end

--- Forget a customer's cached entitlements (after a grant, purchase,
-- subscription, licence or privacy change).
function EntitlementService.bust(app_or_id, customer_id)
    local app = type(app_or_id) == "table" and app_or_id
        or db.query("SELECT id, cache_generation FROM billing_apps WHERE id = ?", app_or_id)[1]
    if not app or not customer_id then return end
    local key = cache_key(app, customer_id)
    -- After the write commits: dropped earlier, a read in between would cache the old access.
    require("queries.FieldServiceCommon").afterCommit(function()
        local RedisClient = require("helper.redis-client")
        local red = RedisClient.connect()
        if red then
            red:del(key)
            RedisClient.release(red)
        end
    end)
end

--- SQL: does subscription row `a` still entitle? One `?` = the app's past-due grace in days.
-- active/trialing until the paid period ends (Stripe ones get a day for the renewal
-- webhook to land); past_due for the grace, counted from when the payment failed.
function EntitlementService.liveSubscriptionSql(a)
    return (([[((%s.status IN ('active', 'trialing') AND (%s.current_period_end IS NULL
            OR %s.current_period_end + CASE WHEN %s.source = 'stripe' THEN interval '1 day' ELSE interval '0' END
               > (NOW() AT TIME ZONE 'UTC')))
        OR (%s.status = 'past_due' AND COALESCE(%s.past_due_since, %s.updated_at) + make_interval(days => ?)
               > (NOW() AT TIME ZONE 'UTC')))]]):gsub("%%s", a))
end

--- Who signs: OPSAPI_PUBLIC_URL (required for signing, lib/billing-signing.lua);
-- never the request's Host header, which clients that pin the issuer would reject.
function EntitlementService.issuer()
    return ((os.getenv("OPSAPI_PUBLIC_URL") or ""):gsub("/+$", ""))
end

local function nullable(v) if v == nil then return NULL end return v end

--- The signed entitlement token (LICENCE_FORMAT.md §2, format v1).
-- @return token | nil, "not configured"
function EntitlementService.token(app, customer, ent)
    local now = ngx.time()
    return require("lib.billing-signing").sign("opsapi-entitlements+jwt", {
        ver = 1,
        iss = EntitlementService.issuer(),
        aud = app.uuid,
        sub = customer.external_id or customer.uuid,
        iat = now,
        exp = ent.expires_at,
        grace_until = ent.expires_at + ent.grace_seconds,
        plan_key = ent.plan and (ent.plan.key or ent.plan.uuid) or NULL,
        status = ent.status,
        features = ent.features,
        access_until = nullable(ent.access_until),
        updates_until = nullable(ent.updates_until),
        offline_policy = ent.offline_policy,
    })
end

--- What a licence may use: the customer's entitlements plus the licence's own
-- plan within its update window, and the licence's own windows.
function EntitlementService.resolveLicense(app, lic, customer)
    local ent = EntitlementService.get(app, customer)
    local features = {}
    for k, v in pairs(ent.features) do features[k] = v end
    local plan, access_until, updates_until = ent.plan, epoch(lic.access_until_epoch), epoch(lic.updates_until_epoch)
    if lic.plan_id then
        local p = db.query("SELECT uuid AS plan_uuid, plan_key, name AS plan_name, features FROM billing_plans WHERE id = ?",
            lic.plan_id)[1]
        if p then
            EntitlementService.merge(features, require("queries.BillingAppQueries").catalogWithReleases(app.id),
                p.features, updates_until)
            plan = plan_ref(p)
        end
    end
    return { plan = plan, features = features, access_until = access_until, updates_until = updates_until,
        offline_policy = ent.offline_policy }
end

--- The signed licence file for an activation (LICENCE_FORMAT.md §2, format v1).
function EntitlementService.licenseFile(app, lic, customer, fingerprint_hash)
    local settings = Settings.resolve(app)
    local r = EntitlementService.resolveLicense(app, lic, customer)
    local now = ngx.time()
    local exp = now + settings.refresh_interval_days * 86400
    if r.access_until and r.access_until < exp then exp = math.max(r.access_until, now) end
    local claims = {
        ver = 1,
        iss = EntitlementService.issuer(),
        aud = app.uuid,
        sub = lic.uuid,
        iat = now,
        exp = exp,
        grace_until = exp + settings.grace_days * 86400,
        plan_key = r.plan and (r.plan.key or r.plan.uuid) or NULL,
        features = r.features,
        access_until = nullable(r.access_until),
        updates_until = nullable(r.updates_until),
        fingerprint_hash = fingerprint_hash,
        offline_policy = settings.offline_policy,
    }
    local token, err = require("lib.billing-signing").sign("opsapi-license+jwt", claims)
    if not token then return nil, err end
    return {
        license_file = token,
        license = { uuid = lic.uuid, status = lic.status, access_until = r.access_until, updates_until = r.updates_until },
        plan = r.plan,
        features = r.features,
        expires_at = claims.exp,
        grace_until = claims.grace_until,
    }
end

return EntitlementService
