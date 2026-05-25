--[[
    Billing Payment Queries
    =======================

    The payment ledger (`billing_payments`) — one row per checkout/payment
    attempt. A 'pending' row is created when checkout starts; the webhook
    (Phase 5) upserts it to its terminal state. The UNIQUE indexes on
    stripe_payment_intent_id / stripe_checkout_session_id make that idempotent.

    Amounts are MINOR units (pence).
]]

local BillingPaymentModel = require("models.BillingPaymentModel")
local Global = require("helper.global")
local db = require("lapis.db")
local cjson = require("cjson")

local BillingPaymentQueries = {}

local function as_json(v)
    if v == nil then return nil end
    if type(v) == "table" then return cjson.encode(v) end
    return v
end

-- Create a pending payment row at checkout start.
function BillingPaymentQueries.createPending(params)
    params.uuid = params.uuid or Global.generateUUID()
    params.status = params.status or "pending"
    params.provider = params.provider or "stripe"
    params.payment_type = params.payment_type or "one_time"
    params.currency = (params.currency or "gbp"):lower()
    params.amount = math.floor(tonumber(params.amount) or 0)
    params.application_fee_amount = math.floor(tonumber(params.application_fee_amount) or 0)
    params.metadata = as_json(params.metadata)
    params.created_at = db.raw("NOW()")
    params.updated_at = db.raw("NOW()")
    return BillingPaymentModel:create(params, { returning = "*" })
end

function BillingPaymentQueries.getByUuid(uuid)
    local rows = db.query("SELECT * FROM billing_payments WHERE uuid = ? LIMIT 1", uuid)
    return rows and rows[1] or nil
end

function BillingPaymentQueries.getBySessionId(session_id)
    if not session_id or session_id == "" then return nil end
    local rows = db.query(
        "SELECT * FROM billing_payments WHERE stripe_checkout_session_id = ? LIMIT 1", session_id)
    return rows and rows[1] or nil
end

function BillingPaymentQueries.getByPaymentIntentId(pi_id)
    if not pi_id or pi_id == "" then return nil end
    local rows = db.query(
        "SELECT * FROM billing_payments WHERE stripe_payment_intent_id = ? LIMIT 1", pi_id)
    return rows and rows[1] or nil
end

-- Update a payment by uuid.
function BillingPaymentQueries.update(uuid, fields)
    local row = BillingPaymentModel:find({ uuid = uuid })
    if not row then return nil end
    fields.updated_at = db.raw("NOW()")
    if fields.metadata ~= nil then fields.metadata = as_json(fields.metadata) end
    row:update(fields)
    return row
end

-- List a user's payments in a namespace (most recent first).
function BillingPaymentQueries.listForUser(namespace_id, user_uuid, opts)
    opts = opts or {}
    local limit = tonumber(opts.limit) or 50
    local rows = db.query(
        "SELECT * FROM billing_payments WHERE namespace_id = ? AND user_uuid = ? " ..
        "ORDER BY created_at DESC LIMIT ?", namespace_id, user_uuid, limit)
    return rows or {}
end

return BillingPaymentQueries
