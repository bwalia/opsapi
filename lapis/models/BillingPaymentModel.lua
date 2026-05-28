-- Payment ledger row (one-time + subscription invoices), namespace-scoped.
-- Thin Lapis model; business logic lives in queries/BillingPaymentQueries.lua.
local Model = require("lapis.db.model").Model
local BillingPayments = Model:extend("billing_payments", { timestamp = true })
return BillingPayments
