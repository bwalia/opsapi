--[[
    Billing — Checkout (subscriptions + one-time)
    ==============================================

    Standard single-merchant Stripe: the platform's OWN Stripe account
    (STRIPE_SECRET_KEY in .env) is the merchant — funds settle directly to it.
    No Stripe Connect / connected accounts. Anyone who self-hosts OpsAPI just
    sets their own Stripe keys in .env and billing works.

    Works for web (hosted Checkout URL) and mobile (native Payment Sheet via a
    PaymentIntent client_secret, one-time only).

    success/cancel URLs are server-controlled (our own public callback that
    302s to the namespace's allow-listed dashboard) — never client-supplied.

    Endpoints:
      POST /api/v2/billing/checkout                 (auth)   hosted Checkout Session -> { checkout_url }
      POST /api/v2/billing/checkout/payment-intent  (auth)   native one-time PaymentIntent -> { client_secret }
      GET  /api/v2/billing/checkout/:session_id     (auth)   session status
      GET  /api/v2/public/billing/checkout/return   (public) 302 to dashboard (success|cancel)

    Local billing_payments rows are created 'pending' here and reconciled to
    their terminal state by the webhook; the unique Stripe-id indexes keep that
    idempotent.
]]

local cjson = require("cjson")
local AuthMiddleware = require("middleware.auth")
local NamespaceMiddleware = require("middleware.namespace")
local PaymentProvider = require("lib.payment-provider")
local BillingUrls = require("lib.billing-urls")
local BillingPlanQueries = require("queries.BillingPlanQueries")
local BillingPaymentQueries = require("queries.BillingPaymentQueries")
local NamespaceQueries = require("queries.NamespaceQueries")
local Global = require("helper.global")

return function(app)
    local function parse_json_body()
        ngx.req.read_body()
        local body = ngx.req.get_body_data()
        if not body or body == "" then return {} end
        local ok, data = pcall(cjson.decode, body)
        return ok and data or {}
    end

    local function api_response(status, data, error_msg)
        if error_msg then
            return { status = status, json = { success = false, error = error_msg } }
        end
        return { status = status, json = { success = true, data = data } }
    end

    local function truthy(v)
        return v == true or v == "t" or v == "true" or v == 1
    end

    -- Load the caller's own plan and validate it. Returns (plan) or (nil, status, err).
    local function load_owned_plan(self, plan_uuid)
        if not plan_uuid or plan_uuid == "" then
            return nil, 400, "plan_uuid is required"
        end
        local plan = BillingPlanQueries.getByUuid(plan_uuid)
        if not plan then return nil, 404, "Plan not found" end
        if tonumber(plan.namespace_id) ~= tonumber(self.namespace.id) then
            return nil, 403, "Access denied"
        end
        if not truthy(plan.active) then
            return nil, 409, "Plan is not active"
        end
        return plan
    end

    -- Resolve the platform Stripe client and ensure the plan has a synced
    -- stripe_price_id (product/price created on the platform account on demand).
    -- Returns (ctx, nil) or (nil, status, err).
    local function prepare_charge(plan)
        if not PaymentProvider.stripe_configured() then
            return nil, 503, "Billing is not configured"
        end
        local stripe = PaymentProvider.get_stripe()
        if not stripe then return nil, 503, "Billing is not configured" end

        local synced, serr = BillingPlanQueries.ensureStripeSync(plan, stripe)
        if serr or not synced or not synced.stripe_price_id or synced.stripe_price_id == "" then
            return nil, 502, "Failed to sync plan to Stripe: " .. tostring(serr or "no price")
        end

        return { stripe = stripe, plan = synced }
    end

    local function shared_metadata(self, plan)
        return {
            namespace_id = tostring(self.namespace.id),
            namespace_uuid = self.namespace.uuid or "",
            user_uuid = self.current_user.uuid,
            plan_uuid = plan.uuid,
            payment_type = plan.plan_type,
        }
    end

    -- ----------------------------------------------------------------------
    -- POST /api/v2/billing/checkout  (hosted Checkout Session; web + mobile)
    -- ----------------------------------------------------------------------
    app:post("/api/v2/billing/checkout", AuthMiddleware.requireAuth(
        NamespaceMiddleware.requireNamespace(function(self)
            local body = parse_json_body()
            local plan, pstatus, perr = load_owned_plan(self, body.plan_uuid)
            if not plan then return api_response(pstatus, nil, perr) end

            local ctx, cstatus, cerr = prepare_charge(plan)
            if not ctx then return api_response(cstatus, nil, cerr) end
            plan = ctx.plan

            local base = BillingUrls.opsapi_base()
            if not base then
                return api_response(500, nil, "Server public URL not configured (set OPSAPI_PUBLIC_URL)")
            end
            local ns_ref = ngx.escape_uri(self.namespace.uuid or tostring(self.namespace.id))
            -- Stripe substitutes {CHECKOUT_SESSION_ID}; keep it un-escaped.
            local success_url = base .. "/api/v2/public/billing/checkout/return?ns=" .. ns_ref ..
                "&result=success&session_id={CHECKOUT_SESSION_ID}"
            local cancel_url = base .. "/api/v2/public/billing/checkout/return?ns=" .. ns_ref .. "&result=cancel"

            local meta = shared_metadata(self, plan)
            local opts = {
                mode = (plan.plan_type == "subscription") and "subscription" or "payment",
                line_items = { { price = plan.stripe_price_id, quantity = 1 } },
                success_url = success_url,
                cancel_url = cancel_url,
                customer_email = self.current_user.email,
                client_reference_id = self.current_user.uuid,
                metadata = meta,
            }

            if plan.plan_type == "subscription" then
                local sub = { metadata = meta }
                local trial = tonumber(plan.trial_days)
                if trial and trial > 0 then sub.trial_period_days = math.floor(trial) end
                opts.subscription_data = sub
            else
                opts.payment_intent_data = { metadata = meta }
            end

            local session, serr = ctx.stripe:create_checkout_session(opts)
            if not session or not session.id then
                ngx.log(ngx.ERR, "Checkout: create_checkout_session failed: " .. tostring(serr))
                return api_response(502, nil, "Failed to start checkout: " .. (serr or "unknown error"))
            end

            -- Pending ledger row (idempotent via unique session index).
            if not BillingPaymentQueries.getBySessionId(session.id) then
                BillingPaymentQueries.createPending({
                    namespace_id = self.namespace.id,
                    user_uuid = self.current_user.uuid,
                    plan_id = plan.id,
                    payment_type = plan.plan_type,
                    stripe_checkout_session_id = session.id,
                    amount = plan.amount,
                    currency = plan.currency,
                    receipt_email = self.current_user.email,
                    metadata = { plan_uuid = plan.uuid },
                })
            end

            return api_response(200, {
                session_id = session.id,
                checkout_url = session.url,
                mode = opts.mode,
            })
        end)
    ))

    -- ----------------------------------------------------------------------
    -- POST /api/v2/billing/checkout/payment-intent  (native sheet; one-time)
    -- ----------------------------------------------------------------------
    app:post("/api/v2/billing/checkout/payment-intent", AuthMiddleware.requireAuth(
        NamespaceMiddleware.requireNamespace(function(self)
            local body = parse_json_body()
            local plan, pstatus, perr = load_owned_plan(self, body.plan_uuid)
            if not plan then return api_response(pstatus, nil, perr) end
            if plan.plan_type ~= "one_time" then
                return api_response(400, nil,
                    "The native payment sheet supports one-time plans only; use /checkout for subscriptions")
            end

            local ctx, cstatus, cerr = prepare_charge(plan)
            if not ctx then return api_response(cstatus, nil, cerr) end
            plan = ctx.plan

            local meta = shared_metadata(self, plan)
            local pi, serr = ctx.stripe:create_payment_intent_minor({
                amount = plan.amount,
                currency = plan.currency,
                receipt_email = self.current_user.email,
                description = plan.name,
                metadata = meta,
            })
            if not pi or not pi.id then
                ngx.log(ngx.ERR, "Checkout PI: create_payment_intent_minor failed: " .. tostring(serr))
                return api_response(502, nil, "Failed to start payment: " .. (serr or "unknown error"))
            end

            if not BillingPaymentQueries.getByPaymentIntentId(pi.id) then
                BillingPaymentQueries.createPending({
                    namespace_id = self.namespace.id,
                    user_uuid = self.current_user.uuid,
                    plan_id = plan.id,
                    payment_type = "one_time",
                    stripe_payment_intent_id = pi.id,
                    amount = plan.amount,
                    currency = plan.currency,
                    receipt_email = self.current_user.email,
                    metadata = { plan_uuid = plan.uuid },
                })
            end

            return api_response(200, {
                payment_intent_id = pi.id,
                client_secret = pi.client_secret,
                publishable_key = PaymentProvider.stripe_config().publishable_key,
                amount = tonumber(plan.amount),
                currency = plan.currency,
            })
        end)
    ))

    -- ----------------------------------------------------------------------
    -- GET /api/v2/billing/checkout/:session_id  (status)
    -- ----------------------------------------------------------------------
    app:get("/api/v2/billing/checkout/:session_id", AuthMiddleware.requireAuth(
        NamespaceMiddleware.requireNamespace(function(self)
            local stripe = PaymentProvider.get_stripe()
            if not stripe then return api_response(503, nil, "Billing is not configured") end

            local session = stripe:retrieve_checkout_session(self.params.session_id)
            if not session or not session.id then
                return api_response(404, nil, "Checkout session not found")
            end
            -- Tenant isolation: the session metadata must match this namespace.
            local meta_ns = session.metadata and session.metadata.namespace_id
            if meta_ns and tostring(meta_ns) ~= tostring(self.namespace.id) then
                return api_response(403, nil, "Access denied")
            end

            return api_response(200, {
                session_id = session.id,
                status = session.status,
                payment_status = session.payment_status,
                subscription = session.subscription,
                payment_intent = type(session.payment_intent) == "table"
                    and session.payment_intent.id or session.payment_intent,
            })
        end)
    ))

    -- ----------------------------------------------------------------------
    -- GET /api/v2/public/billing/checkout/return  (browser redirect target)
    -- Pure, safe redirect to the namespace's allow-listed dashboard.
    -- ----------------------------------------------------------------------
    app:get("/api/v2/public/billing/checkout/return", function(self)
        local result = self.params.result or "return"
        local target
        local ns = self.params.ns
        if ns and ns ~= "" then
            local namespace = NamespaceQueries.findByIdentifier(ns)
            if namespace then
                target = BillingUrls.dashboard_url(namespace.id, "BILLING_DASHBOARD_PATH", "/settings/billing",
                    { checkout = result, session_id = self.params.session_id })
            end
        end
        if not target then
            local fe = Global.getEnvVar("FRONTEND_URL")
            target = (fe and fe ~= "" and (fe:gsub("/+$", "") .. "/?checkout=" .. result)) or "/"
        end
        return { redirect_to = target }
    end)
end
