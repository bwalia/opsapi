--[[
    Billing — Stripe webhook (single-merchant)
    ==========================================

    The authoritative, server-to-server source of truth. Stripe POSTs events
    here; we verify the signature, dedupe, and reconcile billing_payments /
    billing_subscriptions to their terminal state.

    POST /api/v2/public/billing/webhook   (public, auth-exempt via /public/)

    Security & reliability:
      - Signature verified against STRIPE_WEBHOOK_SECRET over the RAW body.
      - Idempotent: stripe_webhook_events.event_id is unique; an event already
        marked 'processed' is skipped, but 'received'/'failed' re-runs on retry.
      - Handlers are idempotent (keyed by Stripe ids), so reprocessing is safe.
      - We return 2xx once handled; 5xx on a handler error so Stripe retries.

    Handled events:
      checkout.session.completed
      customer.subscription.created | .updated | .deleted
      invoice.paid | invoice.payment_failed
      payment_intent.succeeded | payment_intent.payment_failed
      charge.refunded
]]

local cjson = require("cjson")
local Stripe = require("lib.stripe")
local PaymentProvider = require("lib.payment-provider")
local StripeWebhookQueries = require("queries.StripeWebhookQueries")
local BillingPaymentQueries = require("queries.BillingPaymentQueries")
local BillingSubscriptionQueries = require("queries.BillingSubscriptionQueries")
local BillingPlanQueries = require("queries.BillingPlanQueries")

-- Treat JSON null / empty string as nil.
local function nz(v)
    if v == nil or v == cjson.null or v == "" then return nil end
    return v
end

-- A Stripe field that may be a bare id string or an expanded object.
local function id_of(v)
    v = nz(v)
    if type(v) == "table" then return nz(v.id) end
    return v
end

-- Resolve { namespace_id, user_uuid, plan_id } from a Stripe object's metadata.
local function context_from_metadata(meta)
    meta = meta or {}
    local plan_id
    local plan_uuid = nz(meta.plan_uuid)
    if plan_uuid then
        local plan = BillingPlanQueries.getByUuid(plan_uuid)
        if plan then plan_id = plan.id end
    end
    return {
        namespace_id = tonumber(nz(meta.namespace_id)),
        user_uuid = nz(meta.user_uuid),
        plan_id = plan_id,
    }
end

-- An invoice's subscription link and tenant metadata moved under
-- invoice.parent.subscription_details in 2025+ Stripe API versions — the
-- top-level invoice.subscription / invoice.payment_intent fields are now null.
-- Resolve from every known location so renewals and proration (upgrade)
-- invoices are recorded, not just first-checkout ones.
local function invoice_subscription_id(invoice)
    local sd = invoice.parent and invoice.parent.subscription_details
    local ln = invoice.lines and invoice.lines.data and invoice.lines.data[1]
    local lp = ln and ln.parent and ln.parent.subscription_item_details
    return id_of(invoice.subscription)
        or (sd and id_of(sd.subscription))
        or (lp and id_of(lp.subscription))
end

local function invoice_metadata(invoice)
    local sd = invoice.parent and invoice.parent.subscription_details
    return (sd and sd.metadata) or invoice.metadata or {}
end

-- ── Event handlers ──────────────────────────────────────────────────────────
-- Each receives the event's data.object and may raise on a hard failure
-- (caller pcall's them and returns 5xx so Stripe retries).

local handlers = {}

function handlers.checkout_session_completed(session)
    local meta = session.metadata or {}
    local ctx = context_from_metadata(meta)
    local paid = nz(session.payment_status) == "paid"

    -- For a subscription checkout, ensure the subscription row exists and link it.
    local subscription_row_id
    if nz(session.mode) == "subscription" and id_of(session.subscription) then
        local sub, serr = BillingSubscriptionQueries.upsert({
            stripe_subscription_id = id_of(session.subscription),
            stripe_customer_id = id_of(session.customer),
            status = "active",
            plan_id = ctx.plan_id,
            namespace_id = ctx.namespace_id,
            user_uuid = ctx.user_uuid,
            metadata = meta,
        })
        if sub then subscription_row_id = sub.id end
        if serr then ngx.log(ngx.WARN, "webhook checkout: subscription upsert: " .. tostring(serr)) end
    end

    local fields = {
        status = paid and "succeeded" or "processing",
        stripe_payment_intent_id = id_of(session.payment_intent),
        stripe_customer_id = id_of(session.customer),
        stripe_invoice_id = id_of(session.invoice),
        subscription_id = subscription_row_id,
    }

    local existing = BillingPaymentQueries.getBySessionId(session.id)
    if existing then
        BillingPaymentQueries.update(existing.uuid, fields)
    elseif ctx.namespace_id then
        -- No pending row (e.g. created out-of-band) — record it now.
        BillingPaymentQueries.createPending({
            namespace_id = ctx.namespace_id,
            user_uuid = ctx.user_uuid,
            plan_id = ctx.plan_id,
            payment_type = nz(meta.payment_type) or (nz(session.mode) == "subscription" and "subscription" or "one_time"),
            stripe_checkout_session_id = session.id,
            stripe_payment_intent_id = fields.stripe_payment_intent_id,
            stripe_customer_id = fields.stripe_customer_id,
            stripe_invoice_id = fields.stripe_invoice_id,
            subscription_id = subscription_row_id,
            amount = tonumber(session.amount_total) or 0,
            currency = nz(session.currency) or "gbp",
            status = fields.status,
        })
    end
end

local function upsert_subscription_from_object(sub, deleted, event)
    local meta = sub.metadata or {}
    local ctx = context_from_metadata(meta)

    -- The first item carries the price and (in 2025+ Stripe API versions) the
    -- period boundaries that used to live on the subscription object itself.
    local item = sub.items and sub.items.data and sub.items.data[1]

    -- Resolve the plan from the CURRENT PRICE first — it is authoritative and
    -- changes on upgrade/downgrade. metadata.plan_uuid only reflects the plan
    -- the subscription was CREATED with (it goes stale after a plan switch),
    -- so it's a fallback for the rare case the price isn't in our catalogue.
    local plan_id
    if item and item.price then
        local plan = BillingPlanQueries.getByStripePriceId(id_of(item.price))
        if plan then plan_id = plan.id end
    end
    if not plan_id then plan_id = ctx.plan_id end

    -- Period dates: top-level (older API) OR on the item (newer API).
    local period_start = nz(sub.current_period_start) or (item and nz(item.current_period_start))
    local period_end = nz(sub.current_period_end) or (item and nz(item.current_period_end))

    local _, err = BillingSubscriptionQueries.upsert({
        stripe_subscription_id = sub.id,
        stripe_customer_id = id_of(sub.customer),
        status = deleted and "canceled" or nz(sub.status),
        plan_id = plan_id,
        namespace_id = ctx.namespace_id,
        user_uuid = ctx.user_uuid,
        current_period_start = period_start,
        current_period_end = period_end,
        cancel_at_period_end = sub.cancel_at_period_end,
        canceled_at = nz(sub.canceled_at),
        trial_start = nz(sub.trial_start),
        trial_end = nz(sub.trial_end),
        ended_at = deleted and (nz(sub.ended_at) or os.time()) or nz(sub.ended_at),
        metadata = meta,
        last_event_id = event and event.id,
    })
    if err then ngx.log(ngx.WARN, "webhook subscription upsert: " .. tostring(err)) end
end

function handlers.customer_subscription_created(sub, event) upsert_subscription_from_object(sub, false, event) end
function handlers.customer_subscription_updated(sub, event) upsert_subscription_from_object(sub, false, event) end
function handlers.customer_subscription_deleted(sub, event) upsert_subscription_from_object(sub, true, event) end

function handlers.invoice_paid(invoice)
    local sub_id = invoice_subscription_id(invoice)
    local pi_id = id_of(invoice.payment_intent)
    local invoice_id = id_of(invoice.id)
    local sub = sub_id and BillingSubscriptionQueries.getByStripeId(sub_id) or nil

    local enrich = {
        status = "succeeded",
        stripe_payment_intent_id = pi_id,
        stripe_invoice_id = invoice_id,
        stripe_customer_id = id_of(invoice.customer),
        receipt_url = nz(invoice.hosted_invoice_url),
        subscription_id = sub and sub.id or nil,
    }

    -- Prefer enriching the existing row (the checkout row carries the invoice id,
    -- or a prior attempt carries the PI) so we don't create a duplicate charge.
    local existing = (invoice_id and BillingPaymentQueries.getByInvoiceId(invoice_id))
        or (pi_id and BillingPaymentQueries.getByPaymentIntentId(pi_id))
    if existing then
        BillingPaymentQueries.update(existing.uuid, enrich)
        return
    end

    -- No existing row — record it. This is the path for renewals AND for
    -- upgrade prorations (always_invoice), neither of which has a checkout row.
    -- Tenant context comes from our subscription row when we have it, else from
    -- the invoice's own metadata (set on the subscription at checkout/change).
    local ctx = context_from_metadata(invoice_metadata(invoice))
    local namespace_id = sub and sub.namespace_id or ctx.namespace_id
    local user_uuid = sub and sub.user_uuid or ctx.user_uuid
    if namespace_id and user_uuid then
        BillingPaymentQueries.createPending({
            namespace_id = namespace_id,
            user_uuid = user_uuid,
            plan_id = (sub and sub.plan_id) or ctx.plan_id,
            subscription_id = sub and sub.id or nil,
            payment_type = "subscription",
            stripe_payment_intent_id = pi_id,
            stripe_invoice_id = invoice_id,
            stripe_customer_id = id_of(invoice.customer),
            amount = tonumber(invoice.amount_paid) or 0,
            currency = nz(invoice.currency) or "gbp",
            receipt_url = nz(invoice.hosted_invoice_url),
            status = "succeeded",
        })
    else
        ngx.log(ngx.WARN, "invoice.paid: no tenant context for invoice " .. tostring(invoice_id))
    end
end

function handlers.invoice_payment_failed(invoice)
    local sub_id = invoice_subscription_id(invoice)
    if sub_id then
        local sub = BillingSubscriptionQueries.getByStripeId(sub_id)
        if sub and sub.status ~= "canceled" then
            BillingSubscriptionQueries.upsert({ stripe_subscription_id = sub_id, status = "past_due" })
        end
    end
end

local function finalize_payment_intent(pi, status)
    -- Match by PI id (native one-time flow) OR by the invoice this PI paid
    -- (subscription flow — the checkout/invoice row has no PI id yet), so we
    -- backfill the PI id + card details onto subscription payments too.
    local row = BillingPaymentQueries.getByPaymentIntentId(pi.id)
        or (id_of(pi.invoice) and BillingPaymentQueries.getByInvoiceId(id_of(pi.invoice))) or nil
    local fields = { status = status, stripe_payment_intent_id = pi.id, stripe_customer_id = id_of(pi.customer) }

    -- `charges` is deprecated in newer API versions in favour of latest_charge
    -- (an id, not expanded) — so card details may be absent from the payload.
    local charge = pi.charges and pi.charges.data and pi.charges.data[1]
    if charge then
        fields.stripe_charge_id = id_of(charge.id)
        fields.receipt_url = nz(charge.receipt_url)
        local card = charge.payment_method_details and charge.payment_method_details.card
        if card then
            fields.payment_method_type = "card"
            fields.card_brand = nz(card.brand)
            fields.card_last4 = nz(card.last4)
        end
    end
    if status == "failed" and pi.last_payment_error then
        fields.failure_code = nz(pi.last_payment_error.code)
        fields.failure_message = nz(pi.last_payment_error.message)
    end

    if row then
        BillingPaymentQueries.update(row.uuid, fields)
    end
end

function handlers.payment_intent_succeeded(pi) finalize_payment_intent(pi, "succeeded") end
function handlers.payment_intent_payment_failed(pi) finalize_payment_intent(pi, "failed") end

function handlers.charge_refunded(charge)
    local pi_id = id_of(charge.payment_intent)
    if not pi_id then return end
    local row = BillingPaymentQueries.getByPaymentIntentId(pi_id)
    if not row then return end
    local refunded = tonumber(charge.amount_refunded) or 0
    local total = tonumber(charge.amount) or 0
    BillingPaymentQueries.update(row.uuid, {
        status = (total > 0 and refunded >= total) and "refunded" or "partially_refunded",
    })
end

-- Map Stripe event types to handler keys.
local DISPATCH = {
    ["checkout.session.completed"] = handlers.checkout_session_completed,
    ["customer.subscription.created"] = handlers.customer_subscription_created,
    ["customer.subscription.updated"] = handlers.customer_subscription_updated,
    ["customer.subscription.deleted"] = handlers.customer_subscription_deleted,
    ["invoice.paid"] = handlers.invoice_paid,
    ["invoice.payment_succeeded"] = handlers.invoice_paid,
    ["invoice.payment_failed"] = handlers.invoice_payment_failed,
    ["payment_intent.succeeded"] = handlers.payment_intent_succeeded,
    ["payment_intent.payment_failed"] = handlers.payment_intent_payment_failed,
    ["charge.refunded"] = handlers.charge_refunded,
}

return function(app)
    app:post("/api/v2/public/billing/webhook", function(self)
        local cfg = PaymentProvider.stripe_config()
        if not cfg.webhook_secret or cfg.webhook_secret == "" then
            ngx.log(ngx.ERR, "Stripe webhook: STRIPE_WEBHOOK_SECRET not configured")
            return { status = 503, json = { error = "Webhook not configured" } }
        end

        -- Verify the signature over the RAW body.
        ngx.req.read_body()
        local body = ngx.req.get_body_data()
        if not body then
            return { status = 400, json = { error = "Empty body" } }
        end
        local sig = ngx.req.get_headers()["stripe-signature"]

        local event, verr = Stripe.construct_event(body, sig, cfg.webhook_secret)
        if not event then
            ngx.log(ngx.WARN, "Stripe webhook: signature verification failed: " .. tostring(verr))
            return { status = 400, json = { error = "Invalid signature" } }
        end

        -- Idempotency / retry-safety.
        local prior = StripeWebhookQueries.beginProcessing({
            event_id = event.id,
            event_type = event.type,
            api_version = event.api_version,
            livemode = event.livemode,
            payload = event,
        })
        if prior == "processed" then
            return { status = 200, json = { received = true, duplicate = true } }
        end

        local handler = DISPATCH[event.type]
        if not handler then
            StripeWebhookQueries.markIgnored(event.id)
            return { status = 200, json = { received = true, ignored = event.type } }
        end

        local object = event.data and event.data.object or {}
        local ok, herr = pcall(handler, object, event)
        if not ok then
            ngx.log(ngx.ERR, "Stripe webhook handler error for ", event.type, ": ", tostring(herr))
            StripeWebhookQueries.markFailed(event.id, herr)
            -- 5xx so Stripe retries; beginProcessing left it un-'processed'.
            return { status = 500, json = { error = "Handler failed" } }
        end

        StripeWebhookQueries.markProcessed(event.id)
        return { status = 200, json = { received = true } }
    end)
end
