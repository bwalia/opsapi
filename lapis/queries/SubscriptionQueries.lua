--[[
    Academy Subscription Queries
    ============================
    Persists learner <-> community subscriptions, mirrored from Stripe via the
    webhook. Stripe sends `current_period_end` as a unix timestamp; we store it
    as a real timestamp via to_timestamp().
]]

local AcademySubscriptionModel = require "models.AcademySubscriptionModel"
local Global = require "helper.global"
local db = require("lapis.db")

local SubscriptionQueries = {}

function SubscriptionQueries.findByStripeId(stripe_subscription_id)
    if not stripe_subscription_id then return nil end
    local rows = db.query(
        "SELECT * FROM academy_subscriptions WHERE stripe_subscription_id = ? LIMIT 1",
        stripe_subscription_id)
    return rows and rows[1] or nil
end

--- Create or update a subscription from a Stripe object.
--- params: user_uuid, namespace_id, stripe_subscription_id, stripe_customer_id,
---         status, current_period_end_unix (number|nil)
function SubscriptionQueries.upsert(params)
    local cpe = params.current_period_end_unix and tonumber(params.current_period_end_unix)
    local existing = SubscriptionQueries.findByStripeId(params.stripe_subscription_id)

    if existing then
        if cpe then
            db.query("UPDATE academy_subscriptions SET status = ?, current_period_end = to_timestamp(?), updated_at = NOW() WHERE id = ?",
                params.status, cpe, existing.id)
        else
            db.query("UPDATE academy_subscriptions SET status = ?, updated_at = NOW() WHERE id = ?",
                params.status, existing.id)
        end
        return existing
    end

    return AcademySubscriptionModel:create({
        uuid = Global.generateUUID(),
        user_uuid = params.user_uuid,
        namespace_id = params.namespace_id,
        stripe_subscription_id = params.stripe_subscription_id,
        stripe_customer_id = params.stripe_customer_id,
        status = params.status or "active",
        current_period_end = cpe and db.raw("to_timestamp(" .. cpe .. ")") or nil,
        created_at = db.raw("NOW()"),
        updated_at = db.raw("NOW()"),
    }, { returning = "*" })
end

--- Update status (+ optional period) by Stripe subscription id.
function SubscriptionQueries.updateStatusByStripeId(stripe_subscription_id, status, current_period_end_unix)
    local cpe = current_period_end_unix and tonumber(current_period_end_unix)
    if cpe then
        db.query("UPDATE academy_subscriptions SET status = ?, current_period_end = to_timestamp(?), updated_at = NOW() WHERE stripe_subscription_id = ?",
            status, cpe, stripe_subscription_id)
    else
        db.query("UPDATE academy_subscriptions SET status = ?, updated_at = NOW() WHERE stripe_subscription_id = ?",
            status, stripe_subscription_id)
    end
end

return SubscriptionQueries
