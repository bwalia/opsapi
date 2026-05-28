-- Namespace-scoped billing plan (subscription | one_time).
-- Thin Lapis model; business logic lives in queries/BillingPlanQueries.lua.
local Model = require("lapis.db.model").Model
local BillingPlans = Model:extend("billing_plans", { timestamp = true })
return BillingPlans
