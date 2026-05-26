--[[
    Stripe Webhook Queries
    ======================

    Idempotency + audit for inbound Stripe webhooks. The UNIQUE event_id is the
    idempotency guard: `recordOnce` inserts with ON CONFLICT DO NOTHING and
    reports whether THIS delivery is the first one — so a replayed event is a
    no-op. Handlers then mark the row processed / failed / ignored.
]]

local Global = require("helper.global")
local db = require("lapis.db")
local cjson = require("cjson")

local StripeWebhookQueries = {}

-- Record the event (or bump its attempt count) and return its CURRENT status:
--   'processed' -> already handled successfully; caller should skip.
--   'received' | 'failed' -> first delivery or a retry; caller should process.
-- This makes Stripe retries work: a handler that returned non-2xx left the row
-- un-'processed', so the next delivery re-runs it (handlers are idempotent).
function StripeWebhookQueries.beginProcessing(params)
    local livemode = params.livemode
    if livemode == nil then livemode = db.NULL end
    local rows = db.query([[
        INSERT INTO stripe_webhook_events
            (uuid, event_id, event_type, api_version, livemode, payload, status, attempts, created_at)
        VALUES (?, ?, ?, ?, ?, ?::jsonb, 'received', 1, NOW())
        ON CONFLICT (event_id)
            DO UPDATE SET attempts = stripe_webhook_events.attempts + 1
        RETURNING status
    ]], Global.generateUUID(), params.event_id, params.event_type,
        params.api_version or db.NULL, livemode, cjson.encode(params.payload or {}))
    return (rows and rows[1] and rows[1].status) or "received"
end

function StripeWebhookQueries.markProcessed(event_id)
    db.query("UPDATE stripe_webhook_events SET status = 'processed', processed_at = NOW() WHERE event_id = ?",
        event_id)
end

function StripeWebhookQueries.markIgnored(event_id)
    db.query("UPDATE stripe_webhook_events SET status = 'ignored', processed_at = NOW() WHERE event_id = ?",
        event_id)
end

function StripeWebhookQueries.markFailed(event_id, message)
    db.query(
        "UPDATE stripe_webhook_events SET status = 'failed', error_message = ?, processed_at = NOW() WHERE event_id = ?",
        message and tostring(message):sub(1, 1000) or "error", event_id)
end

return StripeWebhookQueries
