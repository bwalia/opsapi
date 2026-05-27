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

local cjson = require("cjson")
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

    local function parse_json_body()
        ngx.req.read_body()
        local body = ngx.req.get_body_data()
        if not body or body == "" then return {} end
        local ok, data = pcall(cjson.decode, body)
        return ok and data or {}
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

    -- POST /api/v2/billing/subscription/change-plan — upgrade/downgrade.
    -- Swaps the live Stripe subscription's price (prorated); the
    -- customer.subscription.updated webhook reconciles plan_id from the new
    -- price. Target must be an active SUBSCRIPTION plan in this namespace.
    app:post("/api/v2/billing/subscription/change-plan", AuthMiddleware.requireAuth(
        NamespaceMiddleware.requireNamespace(function(self)
            local body = parse_json_body()
            if not body.plan_uuid or body.plan_uuid == "" then
                return api_response(400, nil, "plan_uuid is required")
            end

            local sub = BillingSubscriptionQueries.getActiveForUser(self.namespace.id, self.current_user.uuid)
            if not sub then
                return api_response(404, nil, "No active subscription to change")
            end
            if not sub.stripe_subscription_id or sub.stripe_subscription_id == "" then
                return api_response(409, nil, "Subscription is not linked to Stripe")
            end

            local target = BillingPlanQueries.getByUuid(body.plan_uuid)
            if not target then return api_response(404, nil, "Plan not found") end
            if tonumber(target.namespace_id) ~= tonumber(self.namespace.id) then
                return api_response(403, nil, "Access denied")
            end
            if not truthy(target.active) then
                return api_response(409, nil, "Plan is not active")
            end
            if target.plan_type ~= "subscription" then
                return api_response(400, nil, "Can only switch to another subscription plan")
            end
            if tonumber(target.id) == tonumber(sub.plan_id) then
                return api_response(409, nil, "Already on this plan")
            end

            local stripe, perr = PaymentProvider.get_stripe()
            if not stripe then return api_response(503, nil, perr or "Billing is not configured") end

            -- Ensure the target plan has a Stripe price.
            local synced, serr = BillingPlanQueries.ensureStripeSync(target, stripe)
            if serr or not synced or not synced.stripe_price_id or synced.stripe_price_id == "" then
                return api_response(502, nil, "Failed to sync plan to Stripe: " .. tostring(serr or "no price"))
            end

            -- Need the existing subscription item id to swap its price.
            local current = stripe:retrieve_subscription(sub.stripe_subscription_id)
            local item = current and current.items and current.items.data and current.items.data[1]
            if not item or not item.id then
                return api_response(502, nil, "Could not read current subscription item")
            end

            -- Upgrade vs downgrade decides how the prorated difference is settled:
            --   UPGRADE   (paying more) -> "always_invoice": invoice + charge the
            --             prorated difference NOW so the new plan is paid for as
            --             soon as its features unlock.
            --   DOWNGRADE (paying less) -> "create_prorations": bank the unused
            --             credit and apply it to the NEXT invoice (no refund now).
            local current_plan = sub.plan_id and BillingPlanQueries.getById(sub.plan_id) or nil
            local current_amount = current_plan and tonumber(current_plan.amount) or 0
            local target_amount = tonumber(synced.amount) or 0
            local is_upgrade = target_amount > current_amount
            local proration = is_upgrade and "always_invoice" or "create_prorations"

            local updated, uerr = stripe:update_subscription(sub.stripe_subscription_id, {
                items = { { id = item.id, price = synced.stripe_price_id } },
                proration_behavior = proration,
                cancel_at_period_end = false, -- a plan change re-activates a pending cancel
                -- Keep Stripe's own metadata in step with the new plan so it never
                -- drifts behind the live price (the webhook resolves plan from the
                -- price first, but this keeps the audit trail honest).
                metadata = {
                    plan_uuid = target.uuid,
                    namespace_id = tostring(self.namespace.id),
                    user_uuid = self.current_user.uuid,
                },
            })
            if not updated or not updated.id then
                ngx.log(ngx.ERR, "Change plan failed: " .. tostring(uerr))
                return api_response(502, nil, "Failed to change plan: " .. (uerr or "unknown error"))
            end

            -- Optimistic local update; the webhook also reconciles (idempotent).
            BillingSubscriptionQueries.upsert({
                stripe_subscription_id = sub.stripe_subscription_id,
                plan_id = synced.id,
                cancel_at_period_end = false,
            })

            return api_response(200, {
                plan = plan_brief(synced),
                change_type = is_upgrade and "upgrade" or "downgrade",
                message = is_upgrade
                    and "Your plan has been upgraded. The prorated difference has been charged now."
                    or "Your plan has been changed. Unused credit will be applied to your next invoice.",
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
