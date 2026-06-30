--[[
    Creator Queries  (platform-as-merchant-of-record)
    =================================================
    A "creator" is a namespace (community). We track their payout BANK DETAILS
    (not a Stripe account), an optional per-creator fee override, and their
    community subscription price. The platform-wide default cut % lives in
    academy_settings and is set by the super admin.
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

function CreatorQueries.getAccount(namespace_id)
    return CreatorAccountModel:find({ namespace_id = namespace_id })
end

function CreatorQueries.getOrCreateAccount(namespace_id)
    local acc = CreatorAccountModel:find({ namespace_id = namespace_id })
    if acc then return acc end
    return CreatorAccountModel:create({
        uuid = Global.generateUUID(),
        namespace_id = namespace_id,
        bank_details_complete = false,
        created_at = db.raw("NOW()"),
        updated_at = db.raw("NOW()"),
    }, { returning = "*" })
end

--- Save bank/payout details. Marks complete when the essentials are present
--- (account holder + at least one of account_number / iban).
function CreatorQueries.updateBankDetails(namespace_id, input)
    local acc = CreatorQueries.getOrCreateAccount(namespace_id)
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

--- Super-admin: set (or clear with nil) a per-creator fee override (percent).
function CreatorQueries.setFeeOverride(namespace_id, pct)
    local acc = CreatorQueries.getOrCreateAccount(namespace_id)
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

--- The cut % that applies to a creator: their override, else the global default.
function CreatorQueries.effectiveFeePct(namespace_id)
    local acc = CreatorQueries.getAccount(namespace_id)
    if acc and acc.fee_pct_override ~= nil then
        return tonumber(acc.fee_pct_override) or CreatorQueries.getDefaultFeePct()
    end
    return CreatorQueries.getDefaultFeePct()
end

-- ---- Community subscription plan ------------------------------------------

function CreatorQueries.getActivePlan(namespace_id)
    local rows = db.query(
        "SELECT * FROM creator_subscription_plans WHERE namespace_id = ? AND active = TRUE ORDER BY created_at DESC LIMIT 1",
        namespace_id)
    return rows and rows[1] or nil
end

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
