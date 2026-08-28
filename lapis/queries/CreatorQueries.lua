--[[
    Creator Queries  (platform-as-merchant-of-record)
    =================================================
    A "creator" is an INSTRUCTOR (a user) inside the single academy namespace.
    We track their payout BANK DETAILS (not a Stripe account), an optional
    per-instructor fee override, keyed by user_uuid. The academy-wide community
    subscription plan remains namespace-level. The platform-wide default cut %
    lives in academy_settings and is set by the super admin.
]]

local CreatorAccountModel = require "models.CreatorAccountModel"
local CreatorSubscriptionPlanModel = require "models.CreatorSubscriptionPlanModel"
local Global = require "helper.global"
local db = require("lapis.db")

local CreatorQueries = {}

local BANK_FIELDS = {
    "account_holder_name", "bank_name", "account_number", "routing_number",
    "sort_code", "iban", "swift_bic", "bank_country", "payout_email",
}

-- ---- Instructor payout account (per user_uuid) ---------------------------

function CreatorQueries.getAccount(user_uuid)
    if not user_uuid then return nil end
    return CreatorAccountModel:find({ user_uuid = user_uuid })
end

--- Find or create the instructor's account. namespace_id is optional context
--- (the academy namespace); the row is keyed by user_uuid.
function CreatorQueries.getOrCreateAccount(user_uuid, namespace_id)
    local acc = CreatorQueries.getAccount(user_uuid)
    if acc then return acc end
    return CreatorAccountModel:create({
        uuid = Global.generateUUID(),
        user_uuid = user_uuid,
        namespace_id = namespace_id,
        bank_details_complete = false,
        created_at = db.raw("NOW()"),
        updated_at = db.raw("NOW()"),
    }, { returning = "*" })
end

--- Save bank/payout details. Marks complete when the essentials are present
--- (account holder + at least one of account_number / iban).
function CreatorQueries.updateBankDetails(user_uuid, namespace_id, input)
    local acc = CreatorQueries.getOrCreateAccount(user_uuid, namespace_id)
    local fields = {}
    for _, k in ipairs(BANK_FIELDS) do
        if input[k] ~= nil then fields[k] = input[k] end
    end
    local holder = input.account_holder_name or acc.account_holder_name
    local acct = input.account_number or acc.account_number
    local iban = input.iban or acc.iban
    fields.bank_details_complete = (holder ~= nil and holder ~= "")
        and ((acct ~= nil and acct ~= "") or (iban ~= nil and iban ~= ""))
    fields.updated_at = db.raw("NOW()")
    acc:update(fields)
    return acc
end

--- Super-admin: set (or clear with nil) a per-instructor fee override (percent).
function CreatorQueries.setFeeOverride(user_uuid, pct)
    local acc = CreatorQueries.getOrCreateAccount(user_uuid, nil)
    acc:update({ fee_pct_override = pct, updated_at = db.raw("NOW()") })
    return acc
end

-- ---- Global platform settings (academy_settings) -------------------------

function CreatorQueries.getDefaultFeePct()
    local rows = db.query("SELECT value FROM academy_settings WHERE key = 'default_fee_pct' LIMIT 1")
    local v = rows and rows[1] and tonumber(rows[1].value)
    return v or 20
end

function CreatorQueries.setDefaultFeePct(pct)
    db.query([[
        INSERT INTO academy_settings (key, value, updated_at)
        VALUES ('default_fee_pct', ?, NOW())
        ON CONFLICT (key) DO UPDATE SET value = EXCLUDED.value, updated_at = NOW()
    ]], tostring(pct))
end

--- The cut % that applies to an instructor: their override, else the global
--- default. Passing nil (e.g. platform-owned subscription revenue) yields the
--- default but is not used to compute a creator's net.
function CreatorQueries.effectiveFeePct(user_uuid)
    local acc = CreatorQueries.getAccount(user_uuid)
    if acc and acc.fee_pct_override ~= nil then
        return tonumber(acc.fee_pct_override) or CreatorQueries.getDefaultFeePct()
    end
    return CreatorQueries.getDefaultFeePct()
end

-- ---- Community subscription plans (one active plan PER TIER) --------------

-- All active plans for a namespace, entry-level (lowest tier) first.
function CreatorQueries.getActivePlans(namespace_id)
    return db.query(
        "SELECT * FROM creator_subscription_plans WHERE namespace_id = ? AND active = TRUE ORDER BY tier ASC, amount ASC",
        namespace_id) or {}
end

-- The active plan for a specific tier, or nil.
function CreatorQueries.getActivePlanForTier(namespace_id, tier)
    local rows = db.query(
        "SELECT * FROM creator_subscription_plans WHERE namespace_id = ? AND tier = ? AND active = TRUE LIMIT 1",
        namespace_id, math.max(1, math.floor(tonumber(tier) or 1)))
    return rows and rows[1] or nil
end

-- Backward-compat: the lowest-tier active plan (the entry-level membership).
function CreatorQueries.getActivePlan(namespace_id)
    return CreatorQueries.getActivePlans(namespace_id)[1]
end

-- Create/replace the active plan FOR ITS TIER. Deactivates only the same-tier
-- active plan, so the other tiers (Basic/Pro/Premium…) stay live — that's what
-- makes multiple plans coexist. `fields.tier` defaults to 1 (entry level).
function CreatorQueries.upsertPlan(namespace_id, fields)
    local tier = math.max(1, math.floor(tonumber(fields.tier) or 1))
    db.query("UPDATE creator_subscription_plans SET active = FALSE, updated_at = NOW() WHERE namespace_id = ? AND tier = ? AND active = TRUE",
        namespace_id, tier)
    fields.tier = tier
    fields.uuid = Global.generateUUID()
    fields.namespace_id = namespace_id
    fields.active = true
    fields.created_at = db.raw("NOW()")
    fields.updated_at = db.raw("NOW()")
    return CreatorSubscriptionPlanModel:create(fields, { returning = "*" })
end

return CreatorQueries
