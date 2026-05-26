-- Recurring subscription row, namespace-scoped.
-- Thin Lapis model; logic lives in queries/BillingSubscriptionQueries.lua.
local Model = require("lapis.db.model").Model
local BillingSubscriptions = Model:extend("billing_subscriptions", { timestamp = true })
return BillingSubscriptions
