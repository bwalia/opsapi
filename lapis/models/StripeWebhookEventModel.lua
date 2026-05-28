-- Inbound Stripe webhook event (idempotency + audit).
-- Thin Lapis model; logic lives in queries/StripeWebhookQueries.lua.
local Model = require("lapis.db.model").Model
local StripeWebhookEvents = Model:extend("stripe_webhook_events", { timestamp = false })
return StripeWebhookEvents
