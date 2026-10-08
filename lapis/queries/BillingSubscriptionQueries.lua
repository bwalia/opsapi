--[[
    Billing Subscription Queries
    ============================

    Upsert + lookup for `billing_subscriptions`. Driven by Stripe webhooks
    (customer.subscription.* and checkout.session.completed). Keyed by
    stripe_subscription_id so repeated/out-of-order events converge.

    Stripe sends timestamps as unix seconds; we convert with to_timestamp().
]]

local BillingSubscriptionModel = require("models.BillingSubscriptionModel")
local Global = require("helper.global")
local db = require("lapis.db")
local cjson = require("cjson")

local BillingSubscriptionQueries = {}

-- unix seconds -> a db.raw to_timestamp(), or nil when absent.
local function ts(unix)
    local n = tonumber(unix)
    if not n or n <= 0 then return nil end
    return db.raw(string.format("to_timestamp(%d)", math.floor(n)))
end

function BillingSubscriptionQueries.getByStripeId(sub_id)
    if not sub_id or sub_id == "" then return nil end
    local rows = db.query(
        "SELECT * FROM billing_subscriptions WHERE stripe_subscription_id = ? LIMIT 1", sub_id)
    return rows and rows[1] or nil
end

function BillingSubscriptionQueries.getByUuid(uuid)
    local rows = db.query("SELECT * FROM billing_subscriptions WHERE uuid = ? LIMIT 1", uuid)
    return rows and rows[1] or nil
end

-- Most recent subscription for a user in a namespace (any status).
function BillingSubscriptionQueries.getLatestForUser(namespace_id, user_uuid)
    local rows = db.query(
        "SELECT * FROM billing_subscriptions WHERE namespace_id = ? AND user_uuid = ? " ..
        "ORDER BY created_at DESC LIMIT 1", namespace_id, user_uuid)
    return rows and rows[1] or nil
end

-- The user's current entitling subscription (active / trialing / past_due),
-- most recent first. past_due is still entitling while dunning runs.
function BillingSubscriptionQueries.getActiveForUser(namespace_id, user_uuid)
    local rows = db.query(
        "SELECT * FROM billing_subscriptions WHERE namespace_id = ? AND user_uuid = ? " ..
        "AND status IN ('active','trialing','past_due') ORDER BY created_at DESC LIMIT 1",
        namespace_id, user_uuid)
    return rows and rows[1] or nil
end

-- Insert or update a subscription keyed by stripe_subscription_id.
-- fields:
--   stripe_subscription_id (required), stripe_customer_id, status,
--   plan_id, namespace_id, user_uuid (required for first insert),
--   current_period_start/end, canceled_at, trial_end (unix seconds),
--   cancel_at_period_end (bool), metadata (table)
-- Returns (model, nil) or (nil, error).
function BillingSubscriptionQueries.upsert(fields)
    if not fields.stripe_subscription_id or fields.stripe_subscription_id == "" then
        return nil, "stripe_subscription_id is required"
    end

    local set = {
        updated_at = db.raw("NOW()"),
    }
    if fields.stripe_customer_id ~= nil then set.stripe_customer_id = fields.stripe_customer_id end
    if fields.status ~= nil then set.status = fields.status end
    if fields.plan_id ~= nil then set.plan_id = fields.plan_id end
    if fields.cancel_at_period_end ~= nil then set.cancel_at_period_end = fields.cancel_at_period_end == true end
    if fields.current_period_start ~= nil then set.current_period_start = ts(fields.current_period_start) end
    if fields.current_period_end ~= nil then set.current_period_end = ts(fields.current_period_end) end
    if fields.canceled_at ~= nil then set.canceled_at = ts(fields.canceled_at) end
    if fields.trial_start ~= nil then set.trial_start = ts(fields.trial_start) end
    if fields.trial_end ~= nil then set.trial_end = ts(fields.trial_end) end
    if fields.ended_at ~= nil then set.ended_at = ts(fields.ended_at) end
    if fields.metadata ~= nil then set.metadata = cjson.encode(fields.metadata) end
    -- Track which webhook event last mutated this row (audit / debugging).
    if fields.last_event_id ~= nil then
        set.last_event_id = fields.last_event_id
        set.last_event_at = db.raw("NOW()")
    end

    local existing = BillingSubscriptionQueries.getByStripeId(fields.stripe_subscription_id)
    if existing then
        local m = BillingSubscriptionModel:find({ id = existing.id })
        if not m then return nil, "subscription vanished" end
        m:update(set)
        return m
    end

    -- First insert needs the tenant + user (NOT NULL columns).
    if not fields.namespace_id or not fields.user_uuid then
        return nil, "namespace_id and user_uuid are required to create a subscription"
    end
    set.uuid = Global.generateUUID()
    set.stripe_subscription_id = fields.stripe_subscription_id
    set.namespace_id = fields.namespace_id
    set.user_uuid = fields.user_uuid
    set.status = fields.status or "incomplete"
    set.created_at = db.raw("NOW()")
    return BillingSubscriptionModel:create(set, { returning = "*" })
end

-- ===========================================================================
-- Apps (Billing & Entitlements): subscriptions per app + manual grants.
-- Every function is scoped to the caller's namespace_id.
-- ===========================================================================

local Common = require("queries.FieldServiceCommon")
local Apps = require("queries.BillingAppQueries")

local SUB_SELECT = [[
    SELECT s.uuid, s.status, s.provider, s.current_period_start, s.current_period_end, s.cancel_at_period_end,
           s.canceled_at, s.trial_end, s.created_at, s.updated_at,
           a.uuid AS app_uuid, a.name AS app_name, p.uuid AS plan_uuid, p.plan_key, p.name AS plan_name,
           c.uuid AS customer_uuid, c.external_id AS customer_external_id, c.email AS customer_email
    FROM billing_subscriptions s
    JOIN billing_apps a ON a.id = s.app_id
    LEFT JOIN billing_plans p ON p.id = s.plan_id
    LEFT JOIN customers c ON c.id = s.customer_id
]]

-- WHERE clause for the app/customer/status filters shared by lists.
local function filters(alias, namespace_id, params)
    local where, vals = { alias .. ".namespace_id = ?" }, { namespace_id }
    if Common.nilify(params.app) then
        where[#where + 1] = "(a.uuid = ? OR a.slug = ?)"
        vals[#vals + 1], vals[#vals + 2] = params.app, params.app
    end
    if Common.nilify(params.customer) then
        where[#where + 1] = "c.uuid = ?"
        vals[#vals + 1] = params.customer
    end
    return where, vals
end

function BillingSubscriptionQueries.listForApps(namespace_id, params)
    local where, vals = filters("s", namespace_id, params)
    if Common.nilify(params.status) then
        where[#where + 1] = "s.status = ?"
        vals[#vals + 1] = params.status
    end
    local page, per_page, offset = Common.paging(params)
    local sql = SUB_SELECT .. " WHERE " .. table.concat(where, " AND ")
    local total = db.query("SELECT count(*) AS n FROM (" .. sql .. ") x", unpack(vals))[1].n
    vals[#vals + 1], vals[#vals + 2] = per_page, offset
    local rows = db.query(sql .. " ORDER BY s.created_at DESC LIMIT ? OFFSET ?", unpack(vals))
    return Common.arr(rows), Common.meta(total, page, per_page)
end

function BillingSubscriptionQueries.findForApps(namespace_id, uuid)
    return db.query(SUB_SELECT .. " WHERE s.namespace_id = ? AND s.uuid = ?", namespace_id, uuid)[1]
end

-- ---------------------------------------------------------------------------
-- Grants: access without payment (comped plan, extra feature, trial
-- extension). A grant gives a whole plan of the app and/or feature values.
-- ---------------------------------------------------------------------------

local GRANT_SELECT = [[
    SELECT g.uuid, g.features, g.reason, g.starts_at, g.expires_at, g.granted_by, g.revoked_at, g.created_at,
           a.uuid AS app_uuid, a.name AS app_name, p.uuid AS plan_uuid, p.plan_key, p.name AS plan_name,
           c.uuid AS customer_uuid, c.external_id AS customer_external_id, c.email AS customer_email
    FROM billing_grants g
    JOIN billing_apps a ON a.id = g.app_id
    JOIN customers c ON c.id = g.customer_id
    LEFT JOIN billing_plans p ON p.id = g.plan_id
]]

function BillingSubscriptionQueries.listGrants(namespace_id, params)
    local where, vals = filters("g", namespace_id, params)
    if not Common.to_bool(params.include_revoked, false) then
        where[#where + 1] = "g.revoked_at IS NULL AND (g.expires_at IS NULL OR g.expires_at > NOW())"
    end
    local page, per_page, offset = Common.paging(params)
    local sql = GRANT_SELECT .. " WHERE " .. table.concat(where, " AND ")
    local total = db.query("SELECT count(*) AS n FROM (" .. sql .. ") x", unpack(vals))[1].n
    vals[#vals + 1], vals[#vals + 2] = per_page, offset
    local rows = db.query(sql .. " ORDER BY g.created_at DESC LIMIT ? OFFSET ?", unpack(vals))
    return Common.arr(rows), Common.meta(total, page, per_page)
end

--- A workspace's customer by uuid.
function BillingSubscriptionQueries.customer(namespace_id, uuid)
    if type(uuid) ~= "string" or uuid == "" then return nil end
    return db.query("SELECT id, uuid, external_id, email FROM customers WHERE namespace_id = ? AND uuid = ?",
        namespace_id, uuid)[1]
end

--- A plan of this app (not deleted), by uuid or plan_key.
function BillingSubscriptionQueries.appPlan(app_id, ref)
    if type(ref) ~= "string" or ref == "" then return nil end
    return db.query([[SELECT * FROM billing_plans WHERE app_id = ? AND deleted_at IS NULL
        AND (uuid = ? OR plan_key = ?) LIMIT 1]], app_id, ref, ref)[1]
end

local function timestamp(v, name)
    v = Common.nilify(v)
    if v == nil then return nil end
    if type(v) ~= "string" or not v:match("^%d%d%d%d%-%d%d%-%d%d") then
        return nil, name .. " must be an ISO-8601 date/time"
    end
    return v
end

function BillingSubscriptionQueries.createGrant(namespace_id, actor, b)
    local app = Apps.find(namespace_id, b.app)
    if not app then return nil, "App not found" end
    local customer = BillingSubscriptionQueries.customer(namespace_id, b.customer)
    if not customer then return nil, "Customer not found" end
    local plan
    if Common.nilify(b.plan) then
        plan = BillingSubscriptionQueries.appPlan(app.id, b.plan)
        if not plan then return nil, "Plan not found in this app" end
    end
    local features, ferr = Apps.checkFeatureValues(app.id, b.features)
    if not features then return nil, ferr end
    if not plan and next(features) == nil then return nil, "grant a plan, some features, or both" end
    local starts_at, serr = timestamp(b.starts_at, "starts_at")
    if serr then return nil, serr end
    local expires_at, eerr = timestamp(b.expires_at, "expires_at")
    if eerr then return nil, eerr end
    local reason = Common.nilify(b.reason)
    if reason ~= nil and (type(reason) ~= "string" or #reason > 500) then
        return nil, "reason must be text (max 500)"
    end

    local uuid = Common.uuid()
    local ok, err = pcall(db.query, [[
        INSERT INTO billing_grants (uuid, namespace_id, app_id, customer_id, plan_id, features, reason,
            starts_at, expires_at, granted_by)
        VALUES (?, ?, ?, ?, ?, ?::jsonb, ?, COALESCE(?::timestamptz, NOW()), ?::timestamptz, ?)]],
        uuid, namespace_id, app.id, customer.id, plan and plan.id or db.NULL,
        require("lib.billing-signing").encode(features), reason or db.NULL,
        starts_at or db.NULL, expires_at or db.NULL, actor or db.NULL)
    if not ok then
        if tostring(err):find("invalid input syntax", 1, true) or tostring(err):find("out of range", 1, true) then
            return nil, "starts_at / expires_at must be valid ISO-8601 dates"
        end
        error(err)
    end
    return db.query(GRANT_SELECT .. " WHERE g.uuid = ?", uuid)[1]
end

function BillingSubscriptionQueries.revokeGrant(namespace_id, uuid)
    local res = db.query([[UPDATE billing_grants SET revoked_at = NOW(), updated_at = NOW()
        WHERE namespace_id = ? AND uuid = ? AND revoked_at IS NULL]], namespace_id, uuid)
    if (res.affected_rows or 0) == 0 then return nil, "Grant not found" end
    return true
end

return BillingSubscriptionQueries
