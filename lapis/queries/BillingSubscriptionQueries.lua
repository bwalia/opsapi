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

return BillingSubscriptionQueries
