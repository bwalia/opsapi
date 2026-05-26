--[[
    Billing — Customer account (the user's own subscription / entitlements)
    =======================================================================

    Per-user, namespace-scoped. Not owner-gated — every authenticated member
    manages their OWN subscription here.

    Endpoints:
      GET  /api/v2/billing/subscription          current subscription + plan inline
      GET  /api/v2/billing/entitlements          computed snapshot (what they can do)
      POST /api/v2/billing/subscription/cancel    cancel at period end (keeps access)
      GET  /api/v2/billing/payments              the user's payment history
]]

local AuthMiddleware = require("middleware.auth")
local NamespaceMiddleware = require("middleware.namespace")
local PaymentProvider = require("lib.payment-provider")
local EntitlementService = require("helper.entitlement-service")
local BillingSubscriptionQueries = require("queries.BillingSubscriptionQueries")
local BillingPlanQueries = require("queries.BillingPlanQueries")
local BillingPaymentQueries = require("queries.BillingPaymentQueries")

return function(app)
    local function api_response(status, data, error_msg)
        if error_msg then
            return { status = status, json = { success = false, error = error_msg } }
        end
        return { status = status, json = { success = true, data = data } }
    end

    local function truthy(v)
        return v == true or v == "t" or v == "true" or v == 1
    end

    local function plan_brief(plan)
        if not plan then return nil end
        return {
            uuid = plan.uuid,
            name = plan.name,
            plan_type = plan.plan_type,
            amount = tonumber(plan.amount),
            currency = plan.currency,
            billing_interval = plan.billing_interval,
            interval_count = tonumber(plan.interval_count),
        }
    end

    -- GET /api/v2/billing/subscription — the user's current subscription.
    app:get("/api/v2/billing/subscription", AuthMiddleware.requireAuth(
        NamespaceMiddleware.requireNamespace(function(self)
            local sub = BillingSubscriptionQueries.getActiveForUser(self.namespace.id, self.current_user.uuid)
            if not sub then
                return api_response(200, { has_subscription = false })
            end
            local plan = sub.plan_id and BillingPlanQueries.getById(sub.plan_id) or nil
            return api_response(200, {
                has_subscription = true,
                uuid = sub.uuid,
                status = sub.status,
                current_period_start = sub.current_period_start,
                current_period_end = sub.current_period_end,
                cancel_at_period_end = truthy(sub.cancel_at_period_end),
                trial_end = sub.trial_end,
                plan = plan_brief(plan),
            })
        end)
    ))

    -- GET /api/v2/billing/entitlements — computed snapshot.
    app:get("/api/v2/billing/entitlements", AuthMiddleware.requireAuth(
        NamespaceMiddleware.requireNamespace(function(self)
            return api_response(200, EntitlementService.forUser(self.namespace.id, self.current_user.uuid))
        end)
    ))

    -- POST /api/v2/billing/subscription/cancel — cancel at period end.
    app:post("/api/v2/billing/subscription/cancel", AuthMiddleware.requireAuth(
        NamespaceMiddleware.requireNamespace(function(self)
            local sub = BillingSubscriptionQueries.getActiveForUser(self.namespace.id, self.current_user.uuid)
            if not sub then
                return api_response(404, nil, "No active subscription to cancel")
            end
            if not sub.stripe_subscription_id or sub.stripe_subscription_id == "" then
                return api_response(409, nil, "Subscription is not linked to Stripe")
            end

            local stripe, perr = PaymentProvider.get_stripe()
            if not stripe then return api_response(503, nil, perr or "Billing is not configured") end

            local res, serr = stripe:cancel_subscription(sub.stripe_subscription_id, true)
            if not res or not res.id then
                ngx.log(ngx.ERR, "Cancel subscription failed: " .. tostring(serr))
                return api_response(502, nil, "Failed to cancel subscription: " .. (serr or "unknown error"))
            end

            -- Optimistic local update; the customer.subscription.updated webhook
            -- will also reconcile (idempotent).
            BillingSubscriptionQueries.upsert({
                stripe_subscription_id = sub.stripe_subscription_id,
                cancel_at_period_end = true,
            })

            return api_response(200, {
                cancel_at_period_end = true,
                current_period_end = sub.current_period_end,
                message = "Your subscription will end at the close of the current period.",
            })
        end)
    ))

    -- GET /api/v2/billing/payments — the user's payment history.
    app:get("/api/v2/billing/payments", AuthMiddleware.requireAuth(
        NamespaceMiddleware.requireNamespace(function(self)
            local rows = BillingPaymentQueries.listForUser(self.namespace.id, self.current_user.uuid,
                { limit = tonumber(self.params.limit) or 50 })
            local out = {}
            for i = 1, #rows do
                local p = rows[i]
                out[i] = {
                    uuid = p.uuid,
                    status = p.status,
                    payment_type = p.payment_type,
                    amount = tonumber(p.amount),
                    currency = p.currency,
                    paid_at = p.paid_at,
                    created_at = p.created_at,
                    receipt_url = p.receipt_url,
                }
            end
            return api_response(200, out)
        end)
    ))
end
