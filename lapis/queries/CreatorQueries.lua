--[[
    Creator Queries
    ===============
    A "creator" is a namespace (community). This tracks their Stripe Connect
    account + their community subscription plan (price).
]]

local CreatorAccountModel = require "models.CreatorAccountModel"
local CreatorSubscriptionPlanModel = require "models.CreatorSubscriptionPlanModel"
local Global = require "helper.global"
local db = require("lapis.db")

local CreatorQueries = {}

function CreatorQueries.getAccount(namespace_id)
    return CreatorAccountModel:find({ namespace_id = namespace_id })
end

--- Get the creator account row, creating an empty one (no Stripe account yet).
function CreatorQueries.getOrCreateAccount(namespace_id)
    local acc = CreatorAccountModel:find({ namespace_id = namespace_id })
    if acc then return acc end
    return CreatorAccountModel:create({
        uuid = Global.generateUUID(),
        namespace_id = namespace_id,
        onboarding_status = "none",
        created_at = db.raw("NOW()"),
        updated_at = db.raw("NOW()"),
    }, { returning = "*" })
end

function CreatorQueries.update(namespace_id, fields)
    local acc = CreatorAccountModel:find({ namespace_id = namespace_id })
    if not acc then return nil end
    fields.updated_at = db.raw("NOW()")
    acc:update(fields)
    return acc
end

--- The creator's currently-active community subscription plan, or nil.
function CreatorQueries.getActivePlan(namespace_id)
    local rows = db.query(
        "SELECT * FROM creator_subscription_plans WHERE namespace_id = ? AND active = TRUE ORDER BY created_at DESC LIMIT 1",
        namespace_id)
    return rows and rows[1] or nil
end

--- Replace the active plan with a new one (prices are immutable in Stripe).
function CreatorQueries.upsertPlan(namespace_id, fields)
    db.query("UPDATE creator_subscription_plans SET active = FALSE, updated_at = NOW() WHERE namespace_id = ? AND active = TRUE",
        namespace_id)
    fields.uuid = Global.generateUUID()
    fields.namespace_id = namespace_id
    fields.active = true
    fields.created_at = db.raw("NOW()")
    fields.updated_at = db.raw("NOW()")
    return CreatorSubscriptionPlanModel:create(fields, { returning = "*" })
end

return CreatorQueries
