--[[
    Billing & Entitlements — payments with Stripe (docs/BILLING_ENTITLEMENTS.md §10, §13)
    ====================================================================================
    Each workspace connects its own Stripe Express account. Checkout runs on
    Stripe's hosted page as a destination charge on the platform account:
    the money goes to the workspace's account (`transfer_data`), the
    workspace is the seller (`on_behalf_of`, and the tax liability when Stripe
    Tax is on), and the platform keeps STRIPE_PLATFORM_FEE_PERCENT.

    The database changes only from Stripe webhooks (handle()):
      checkout.session.completed / .async_payment_succeeded -> fulfil, once per session
      customer.subscription.updated / .deleted                -> status, period, plan, licence window
      charge.refunded                                          -> the app's refund_policy
      account.updated                                          -> the connected account's status
    Every Stripe write carries an idempotency key.
]]

local db = require("lapis.db")
local cjson = require("cjson")
local PaymentProvider = require("lib.payment-provider")
local Settings = require("lib.billing-settings")
local Common = require("queries.FieldServiceCommon")

local Pay = {}

local function stripe()
    local client, err = PaymentProvider.get_stripe()
    if not client then return nil, err end
    return client
end

function Pay.mode() return PaymentProvider.stripe_mode() end

local function fee_percent()
    local pct = tonumber(os.getenv("STRIPE_PLATFORM_FEE_PERCENT") or "") or 0
    return math.max(0, math.min(pct, 100))
end

local function hosted(app, page)
    local base = os.getenv("BILLING_HOSTED_BASE_URL")
    if not base or base == "" then return nil end
    return base:gsub("/+$", "") .. "/b/" .. app.uuid .. "/" .. page
end

local function err(status, code, message) return nil, { status = status, code = code, message = message } end

-- ---------------------------------------------------------------------------
-- Connected accounts
-- ---------------------------------------------------------------------------

function Pay.account(namespace_id)
    return db.query("SELECT * FROM billing_connect_accounts WHERE namespace_id = ? AND mode = ?",
        namespace_id, Pay.mode())[1]
end

local function present_account(row)
    if not row then return { connected = false, mode = Pay.mode() } end
    return { connected = true, mode = row.mode, account = row.stripe_account_id, charges_enabled = row.charges_enabled,
        payouts_enabled = row.payouts_enabled, details_submitted = row.details_submitted,
        platform_fee_percent = fee_percent(), updated_at = row.updated_at }
end

--- Whether a workspace can take payments now.
function Pay.ready(namespace_id)
    local a = Pay.account(namespace_id)
    return a ~= nil and a.charges_enabled == true
end

local function save_account(obj)
    db.query([[UPDATE billing_connect_accounts SET charges_enabled = ?, payouts_enabled = ?, details_submitted = ?,
        updated_at = NOW() WHERE stripe_account_id = ?]],
        obj.charges_enabled == true, obj.payouts_enabled == true, obj.details_submitted == true, obj.id)
end

--- The workspace's account status, refreshed from Stripe while onboarding is unfinished.
function Pay.status(namespace_id)
    local row = Pay.account(namespace_id)
    if row and not row.charges_enabled then
        local s = stripe()
        local obj = s and s:_request("GET", "/accounts/" .. row.stripe_account_id)
        if obj and obj.id then
            save_account(obj)
            row = Pay.account(namespace_id)
        end
    end
    return present_account(row)
end

--- Start or resume Stripe onboarding. @return { url } | nil, err
function Pay.onboard(namespace_id, b)
    local s, serr = stripe()
    if not s then return err(503, "payments_not_configured", serr) end
    local back = os.getenv("BILLING_HOSTED_BASE_URL")
    if not back or back == "" then return err(503, "hosted_url_missing", "Set BILLING_HOSTED_BASE_URL") end
    back = back:gsub("/+$", "") .. "/dashboard/billing/payments"
    local row = Pay.account(namespace_id)
    if not row then
        local country = type(b.country) == "string" and b.country:upper():match("^%u%u$") or nil
        local acct, aerr = s:_request("POST", "/accounts", {
            type = "express", country = country,
            capabilities = { card_payments = { requested = true }, transfers = { requested = true } },
            metadata = { opsapi_namespace = tostring(namespace_id) },
        }, ("opsapi-connect-%s-%s"):format(namespace_id, Pay.mode()))
        if not acct then return err(502, "stripe_error", aerr) end
        db.query([[INSERT INTO billing_connect_accounts (namespace_id, mode, stripe_account_id) VALUES (?, ?, ?)
            ON CONFLICT (namespace_id, mode) DO NOTHING]], namespace_id, Pay.mode(), acct.id)
        row = Pay.account(namespace_id)
    end
    local link, lerr = s:_request("POST", "/account_links", { account = row.stripe_account_id, type = "account_onboarding",
        refresh_url = back .. "?stripe=refresh", return_url = back .. "?stripe=return" })
    if not link then return err(502, "stripe_error", lerr) end
    return { url = link.url, account = present_account(row) }
end

-- ---------------------------------------------------------------------------
-- Prices and coupons on the platform account (created on first use)
-- ---------------------------------------------------------------------------

-- The Stripe price of a recurring plan for the current mode; a new one when the
-- plan's amount, currency or interval changed.
local function price_for(s, plan)
    local refs = type(plan.stripe_refs) == "table" and plan.stripe_refs or {}
    local mode = Pay.mode()
    local ref = refs[mode] or {}
    local want = { amount = tonumber(plan.amount), currency = plan.currency:lower(),
        interval = plan.billing_interval, interval_count = tonumber(plan.interval_count) or 1 }
    if ref.price and ref.amount == want.amount and ref.currency == want.currency and ref.interval == want.interval
        and ref.interval_count == want.interval_count then
        return ref.price
    end
    if not ref.product then
        local product, perr = s:_request("POST", "/products", { name = plan.name, metadata = { opsapi_plan = plan.uuid } },
            "opsapi-product-" .. plan.uuid)
        if not product then return nil, perr end
        ref.product = product.id
    end
    local price, perr = s:_request("POST", "/prices", { product = ref.product, currency = want.currency,
        unit_amount = want.amount, recurring = { interval = want.interval, interval_count = want.interval_count },
        metadata = { opsapi_plan = plan.uuid } },
        ("opsapi-price-%s-%s-%s-%s-%s"):format(plan.uuid, want.amount, want.currency, want.interval, want.interval_count))
    if not price then return nil, perr end
    want.product, want.price = ref.product, price.id
    refs[mode] = want
    db.query("UPDATE billing_plans SET stripe_refs = ?::jsonb WHERE id = ?", cjson.encode(refs), plan.id)
    return price.id
end

-- The Stripe coupon for an OpsAPI coupon (keyed by mode and terms, so edited terms get a new one).
local function coupon_for(s, c)
    local terms = table.concat({ c.discount_type, tostring(c.percent_off ~= db.NULL and c.percent_off or ""),
        tostring(c.amount_off ~= db.NULL and c.amount_off or ""), tostring(c.currency ~= db.NULL and c.currency or ""),
        c.duration or "once", tostring(c.duration_months ~= db.NULL and c.duration_months or "") }, ":")
    local key = Pay.mode() .. ":" .. ngx.md5(terms)
    local refs = type(c.stripe_refs) == "table" and c.stripe_refs or {}
    if refs[key] then return refs[key] end
    local body = { duration = c.duration or "once", name = c.code, metadata = { opsapi_coupon = c.uuid } }
    if c.discount_type == "percent" then
        body.percent_off = tonumber(c.percent_off)
    else
        body.amount_off, body.currency = tonumber(c.amount_off), tostring(c.currency):lower()
    end
    if body.duration == "repeating" then body.duration_in_months = tonumber(c.duration_months) end
    local coupon, cerr = s:_request("POST", "/coupons", body, "opsapi-coupon-" .. c.uuid .. "-" .. key)
    if not coupon then return nil, cerr end
    refs[key] = coupon.id
    db.query("UPDATE billing_coupons SET stripe_refs = ?::jsonb WHERE id = ?", cjson.encode(refs), c.id)
    return coupon.id
end

-- ---------------------------------------------------------------------------
-- Checkout
-- ---------------------------------------------------------------------------

local function latest_stripe_customer(namespace_id, customer_id)
    if not customer_id then return nil end
    local r = db.query([[SELECT stripe_customer_id FROM billing_subscriptions WHERE namespace_id = ? AND customer_id = ?
        AND stripe_customer_id IS NOT NULL ORDER BY created_at DESC LIMIT 1]], namespace_id, customer_id)[1]
    return r and r.stripe_customer_id
end

--- Start a Stripe Checkout session.
-- o: { customer? (row), email?, coupon? (code), success_url?, cancel_url?, from_plan? (upgrade),
--      amount? (upgrade price, one-off plans), idempotency_key }
-- @return { url, session_id } | nil, { status, code, message }
function Pay.checkout(app, plan, o)
    local s, serr = stripe()
    if not s then return err(503, "payments_not_configured", serr) end
    local acct = Pay.account(app.namespace_id)
    if not acct or not acct.charges_enabled then
        return err(409, "payments_not_ready", "This seller can't take payments yet")
    end
    local settings = Settings.resolve(app)
    if Settings.isLicensed(app) and not require("lib.billing-delivery").configured() then
        return err(503, "delivery_not_configured", "Licence key delivery isn't configured (LICENCE_DELIVERY_KEY)")
    end
    local recurring = plan.purchase_type == "recurring"
    local amount = tonumber(o.amount) or tonumber(plan.amount)
    local success = o.success_url or hosted(app, "success")
    local cancel = o.cancel_url or hosted(app, "pricing")
    if not success or not cancel then
        return err(422, "redirect_required", "Send success_url and cancel_url (or set BILLING_HOSTED_BASE_URL)")
    end
    if not o.success_url then success = success .. "?session_id={CHECKOUT_SESSION_ID}" end

    local coupon
    if o.coupon and o.coupon ~= "" then
        local res, code, msg = require("queries.BillingOfferQueries").checkCoupon(app.namespace_id, app, o.coupon, plan,
            amount, plan.currency, o.customer and o.customer.id)
        if not res then return err(422, code, msg) end
        coupon = res
    end

    local meta = { opsapi = "billing", ns = tostring(app.namespace_id), app = app.uuid, plan = plan.uuid,
        kind = o.from_plan and "upgrade" or "new", from_plan = o.from_plan and o.from_plan.uuid or nil,
        customer = o.customer and o.customer.uuid or nil, coupon = coupon and coupon.coupon.uuid or nil }
    local params = {
        mode = recurring and "subscription" or "payment",
        success_url = success, cancel_url = cancel, metadata = meta,
        client_reference_id = o.customer and o.customer.uuid or nil,
    }
    local sc = o.customer and latest_stripe_customer(app.namespace_id, o.customer.id)
    if sc then
        params.customer = sc
    else
        local email = o.email or (o.customer and o.customer.email ~= db.NULL and o.customer.email) or nil
        params.customer_email = email
    end
    if recurring then
        local price, perr = price_for(s, plan)
        if not price then return err(502, "stripe_error", perr) end
        params.line_items = { { price = price, quantity = 1 } }
    else
        params.line_items = { { quantity = 1, price_data = { currency = plan.currency:lower(), unit_amount = amount,
            product_data = { name = o.from_plan and (plan.name .. " (upgrade from " .. o.from_plan.name .. ")")
                or plan.name } } } }
    end
    if coupon then
        local id, cerr = coupon_for(s, coupon.coupon)
        if not id then return err(502, "stripe_error", cerr) end
        params.discounts = { { coupon = id } }
    elseif settings.allow_promotion_codes then
        params.allow_promotion_codes = true
    end
    if settings.automatic_tax then
        params.automatic_tax = { enabled = true, liability = { type = "account", account = acct.stripe_account_id } }
    end
    local pct = fee_percent()
    if recurring then
        params.subscription_data = { metadata = meta, on_behalf_of = acct.stripe_account_id,
            transfer_data = { destination = acct.stripe_account_id },
            application_fee_percent = pct > 0 and pct or nil,
            trial_period_days = (tonumber(plan.trial_days) or 0) > 0 and tonumber(plan.trial_days) or nil }
        if settings.automatic_tax then
            params.subscription_data.invoice_settings = { issuer = { type = "account", account = acct.stripe_account_id } }
        end
    else
        local fee = math.floor((amount - (coupon and coupon.discount or 0)) * pct / 100)
        params.payment_intent_data = { metadata = meta, on_behalf_of = acct.stripe_account_id,
            transfer_data = { destination = acct.stripe_account_id },
            application_fee_amount = fee > 0 and fee or nil }
    end
    local session, cerr = s:_request("POST", "/checkout/sessions", params,
        o.idempotency_key and ("opsapi-checkout-%s-%s"):format(app.id, o.idempotency_key) or nil)
    if not session then return err(502, "stripe_error", cerr) end
    return { url = session.url, session_id = session.id }
end

local function stripe_subscription(app, customer_id)
    return db.query([[SELECT * FROM billing_subscriptions WHERE app_id = ? AND customer_id = ? AND source = 'stripe'
        AND status IN ('active', 'trialing', 'past_due') ORDER BY created_at DESC LIMIT 1]], app.id, customer_id)[1]
end
Pay.stripeSubscription = stripe_subscription

--- Buy `plan`. A known customer on another plan with an upgrade path to this
-- one pays the path's price (a free path is applied at once); a customer who
-- already pays for a Stripe subscription switches it instead.
-- o: as Pay.checkout, minus from_plan / amount.
-- @return { url, session_id } | { upgraded = true, ... } | nil, err
function Pay.start(app, plan, customer, o)
    o.customer = customer
    if customer then
        local Purchases = require("queries.BillingPurchaseQueries")
        if plan.purchase_type == "recurring" and stripe_subscription(app, customer.id) then
            return err(409, "already_subscribed", "Switch the existing subscription instead (upgrade)")
        end
        local cur = Purchases.currentPlan(app, customer.id)
        if cur and tonumber(cur.id) ~= tonumber(plan.id) then
            local price = require("queries.BillingOfferQueries").upgradePrice(app, cur, plan)
            if price then
                o.from_plan = cur
                if plan.purchase_type ~= "recurring" then
                    if price.amount == 0 then
                        local res, uerr, code = Purchases.upgrade(app.namespace_id, "customer",
                            { app = app.uuid, customer = customer.uuid, to_plan = plan.uuid })
                        if not res then return err(422, code or "upgrade_failed", uerr) end
                        res.upgraded = true
                        return res
                    end
                    o.amount = price.amount
                end
            end
        end
    end
    return Pay.checkout(app, plan, o)
end

--- An order's status for the success page. A new licence key is in it once.
function Pay.order(app, session_id)
    local p = db.query([[SELECT pu.*, pl.plan_key, pl.name AS plan_name FROM billing_purchases pu
        JOIN billing_plans pl ON pl.id = pu.plan_id
        WHERE pu.app_id = ? AND pu.source = 'stripe' AND pu.external_transaction_id = ?]], app.id, session_id)[1]
    local sub = not p and db.query([[SELECT s.*, pl.plan_key, pl.name AS plan_name FROM billing_subscriptions s
        JOIN billing_plans pl ON pl.id = s.plan_id
        WHERE s.app_id = ? AND s.source = 'stripe' AND s.external_transaction_id = ?]], app.id, session_id)[1]
    local row = p or sub
    if not row then return { status = "pending" } end
    local out = { status = "complete", plan = { key = row.plan_key, name = row.plan_name } }
    if p then
        out.purchase = require("queries.BillingPurchaseQueries").present(p)
    else
        out.subscription = { uuid = sub.uuid, status = sub.status, current_period_end = sub.current_period_end }
    end
    local lic = db.query(([[SELECT uuid, key_prefix, status, access_until, updates_until FROM billing_licenses
        WHERE %s = ? AND status <> 'revoked' ORDER BY created_at DESC LIMIT 1]]):format(p and "purchase_id" or "subscription_id"),
        row.id)[1]
    if lic then
        out.license = lic
        out.key = require("lib.billing-delivery").reveal(session_id)
        out.key_emailed = Settings.resolve(app).email_licence_keys == true
    end
    return out
end

--- Stripe's Customer Portal for a customer's subscriptions in this workspace.
function Pay.portal(app, customer_id, return_url)
    local s, serr = stripe()
    if not s then return err(503, "payments_not_configured", serr) end
    local sc = latest_stripe_customer(app.namespace_id, customer_id)
    if not sc then return err(404, "no_subscription", "There is no paid subscription to manage") end
    local back = return_url or hosted(app, "account")
    if not back then return err(422, "redirect_required", "Send return_url (or set BILLING_HOSTED_BASE_URL)") end
    local session, perr = s:_request("POST", "/billing_portal/sessions", { customer = sc, return_url = back })
    if not session then return err(502, "stripe_error", perr) end
    return { url = session.url }
end

--- Switch a Stripe subscription to another recurring plan, prorated. @return true | nil, err
function Pay.switchPlan(sub, to_plan)
    local s, serr = stripe()
    if not s then return err(503, "payments_not_configured", serr) end
    local remote, rerr = s:_request("GET", "/subscriptions/" .. sub.stripe_subscription_id)
    if not remote then return err(502, "stripe_error", rerr) end
    local item = remote.items and remote.items.data and remote.items.data[1]
    if not item then return err(502, "stripe_error", "the subscription has no items") end
    local price, perr = price_for(s, to_plan)
    if not price then return err(502, "stripe_error", perr) end
    local ok, uerr = s:_request("POST", "/subscriptions/" .. sub.stripe_subscription_id, {
        items = { { id = item.id, price = price } }, proration_behavior = "create_prorations",
        metadata = { plan = to_plan.uuid } }, ("opsapi-switch-%s-%s"):format(sub.uuid, to_plan.uuid))
    if not ok then return err(502, "stripe_error", uerr) end
    return true
end

--- Refund a Stripe purchase (all of it, or `amount`). The webhook applies the result.
function Pay.refund(namespace_id, uuid, amount)
    local p = db.query("SELECT * FROM billing_purchases WHERE namespace_id = ? AND uuid = ?", namespace_id, uuid)[1]
    if not p then return err(404, "not_found", "Purchase not found") end
    if p.source ~= "stripe" or p.stripe_payment_intent_id == db.NULL or not p.stripe_payment_intent_id then
        return err(422, "not_a_stripe_purchase", "Only purchases paid through Stripe can be refunded here")
    end
    amount = amount ~= nil and tonumber(amount) or nil
    if amount and (amount < 1 or amount ~= math.floor(amount) or amount > tonumber(p.amount)) then
        return err(422, "invalid_amount", "amount must be minor units, at most the amount paid")
    end
    local s, serr = stripe()
    if not s then return err(503, "payments_not_configured", serr) end
    local r, rerr = s:_request("POST", "/refunds", { payment_intent = p.stripe_payment_intent_id, amount = amount,
        reverse_transfer = true, refund_application_fee = true },
        ("opsapi-refund-%s-%s-%s"):format(p.uuid, amount or "full", tonumber(p.refunded_amount) or 0))
    if not r then return err(502, "stripe_error", rerr) end
    return { refund = r.id, status = r.status, amount = r.amount }
end

-- ---------------------------------------------------------------------------
-- Webhook events
-- ---------------------------------------------------------------------------

local function customer_for(namespace_id, meta, details)
    if meta.customer then
        local c = db.query("SELECT * FROM customers WHERE namespace_id = ? AND uuid = ?", namespace_id, meta.customer)[1]
        if c then return c end
    end
    local email = details and details.email
    if type(email) ~= "string" or email == "" then return nil, "the checkout session has no customer email" end
    local c = db.query("SELECT * FROM customers WHERE namespace_id = ? AND lower(email) = lower(?) LIMIT 1",
        namespace_id, email)[1]
    if c then return c end
    local ok, res = pcall(db.insert, "customers", { uuid = Common.uuid(), namespace_id = namespace_id, email = email,
        created_at = db.raw("NOW()"), updated_at = db.raw("NOW()") }, { returning = "*" })
    if ok then return res[1] end
    return db.query("SELECT * FROM customers WHERE namespace_id = ? AND lower(email) = lower(?) LIMIT 1",
        namespace_id, email)[1]
end

local function period_end(sub)
    local t = sub.current_period_end
    if not t and sub.items and sub.items.data and sub.items.data[1] then t = sub.items.data[1].current_period_end end
    return tonumber(t)
end

local function fulfil_session(s)
    local meta = s.metadata or {}
    if meta.opsapi ~= "billing" then return "ignored" end
    if s.payment_status ~= "paid" and s.payment_status ~= "no_payment_required" then return "ignored" end
    local app = db.query("SELECT * FROM billing_apps WHERE uuid = ? AND namespace_id = ?", meta.app,
        tonumber(meta.ns))[1]
    if not app then return "ignored" end
    local plan = db.query("SELECT * FROM billing_plans WHERE uuid = ? AND app_id = ?", meta.plan, app.id)[1]
    if not plan then error("plan " .. tostring(meta.plan) .. " not found") end
    local customer, cerr = customer_for(app.namespace_id, meta, s.customer_details)
    if not customer then error(cerr) end
    local expires_at
    if plan.purchase_type == "recurring" then
        local remote, rerr = stripe():_request("GET", "/subscriptions/" .. tostring(s.subscription))
        if not remote then error("could not read the subscription: " .. tostring(rerr)) end
        expires_at = period_end(remote)
    end
    local Purchases = require("queries.BillingPurchaseQueries")
    local res, ferr = Common.transaction(function()
        db.query("SELECT pg_advisory_xact_lock(hashtext(?))", "opsapi.billing.checkout:" .. s.id)
        local done = db.query([[SELECT 1 FROM billing_purchases WHERE namespace_id = ? AND source = 'stripe'
                AND external_transaction_id = ?
            UNION ALL SELECT 1 FROM billing_subscriptions WHERE namespace_id = ? AND source = 'stripe'
                AND external_transaction_id = ?]], app.namespace_id, s.id, app.namespace_id, s.id)[1]
        if done then return { duplicate = true } end
        local coupon = meta.coupon and db.query("SELECT * FROM billing_coupons WHERE uuid = ? AND namespace_id = ?",
            meta.coupon, app.namespace_id)[1]
        local totals = s.total_details or {}
        local from_plan = meta.from_plan and db.query("SELECT * FROM billing_plans WHERE uuid = ? AND app_id = ?",
            meta.from_plan, app.id)[1]
        local out, e = Purchases.fulfil(app, customer, plan, {
            source = "stripe", external_transaction_id = s.id,
            original_transaction_id = plan.purchase_type == "recurring" and s.subscription or nil,
            amount = (tonumber(s.amount_total) or 0) - (tonumber(totals.amount_tax) or 0), currency = s.currency,
            coupon = coupon, discount = tonumber(totals.amount_discount) or 0, force_coupon = true,
            expires_at = expires_at, kind = meta.kind == "upgrade" and "upgrade" or "new", from_plan = from_plan,
            stripe = { subscription_id = s.subscription, customer_id = s.customer, payment_intent = s.payment_intent },
            actor = "stripe",
        })
        if not out then return nil, e end
        if out.key then
            local email = Settings.resolve(app).email_licence_keys == true
            local lic = db.query("SELECT id FROM billing_licenses WHERE uuid = ?", out.license.uuid)[1]
            local ok, derr = require("lib.billing-delivery").store(lic.id, s.id, out.key, email)
            if not ok then return nil, derr end
            if email then
                require("helper.plugin-events").emit(app.namespace_id, "billing.licence_key.requested",
                    { license = out.license.uuid })
            end
        end
        return out
    end)
    if not res then error(ferr) end
    return true
end

local SUB_STATUS = { incomplete = true, incomplete_expired = true, trialing = true, active = true, past_due = true,
    canceled = true, unpaid = true, paused = true }

local function sync_subscription(sub, deleted)
    if (sub.metadata or {}).opsapi ~= "billing" then return "ignored" end
    local row = db.query("SELECT * FROM billing_subscriptions WHERE stripe_subscription_id = ?", sub.id)[1]
    if not row then return "ignored" end -- not fulfilled yet: the checkout event reads the subscription itself
    local app = db.query("SELECT * FROM billing_apps WHERE id = ?", row.app_id)[1]
    local plan_id = row.plan_id
    if sub.metadata.plan then
        local p = db.query("SELECT id FROM billing_plans WHERE uuid = ? AND app_id = ?", sub.metadata.plan, row.app_id)[1]
        if p then plan_id = p.id end
    end
    local status = deleted and "canceled" or (SUB_STATUS[sub.status] and sub.status or row.status)
    local finish = period_end(sub)
    local ended = tonumber(sub.ended_at)
    Common.transaction(function()
        db.update("billing_subscriptions", {
            status = status, plan_id = plan_id, cancel_at_period_end = sub.cancel_at_period_end == true,
            current_period_end = finish and db.raw(("to_timestamp(%d) AT TIME ZONE 'UTC'"):format(finish))
                or row.current_period_end,
            canceled_at = tonumber(sub.canceled_at) and db.raw(("to_timestamp(%d) AT TIME ZONE 'UTC'"):format(sub.canceled_at))
                or db.NULL,
            ended_at = ended and db.raw(("to_timestamp(%d) AT TIME ZONE 'UTC'"):format(ended)) or db.NULL,
            updated_at = db.raw("NOW()"),
        }, { id = row.id })
        -- The licence of a subscription runs to the end of the paid period (or when it ended).
        local until_ = ended or (status ~= "canceled" and finish) or nil
        if until_ then
            db.query([[UPDATE billing_licenses SET plan_id = ?, access_until = to_timestamp(?), updated_at = NOW(),
                    status = CASE WHEN status = 'expired' AND to_timestamp(?) > NOW() THEN 'active' ELSE status END
                WHERE subscription_id = ? AND status <> 'revoked']], plan_id, until_, until_, row.id)
        end
    end)
    require("helper.entitlement-service").bust(app, row.customer_id)
    return true
end

local function refunded(ch)
    local Purchases = require("queries.BillingPurchaseQueries")
    local p = ch.payment_intent and db.query("SELECT * FROM billing_purchases WHERE stripe_payment_intent_id = ?",
        ch.payment_intent)[1]
    local full = ch.refunded == true
    if p then
        local app = db.query("SELECT * FROM billing_apps WHERE id = ?", p.app_id)[1]
        Common.transaction(function()
            if full and p.status == "active" then
                Purchases.refund(app, p, tonumber(ch.amount_refunded))
            else
                db.query("UPDATE billing_purchases SET refunded_amount = ?, refunded_at = NOW(), updated_at = NOW() WHERE id = ?",
                    tonumber(ch.amount_refunded) or 0, p.id)
                require("helper.entitlement-service").bust(app, p.customer_id)
            end
        end)
        return true
    end
    -- A subscription payment: a full refund under "revoke" ends the subscription now.
    if not (full and ch.invoice) then return "ignored" end
    local s = stripe()
    local inv = s and s:_request("GET", "/invoices/" .. ch.invoice)
    local sub_id = inv and (inv.subscription or (inv.parent and inv.parent.subscription_details
        and inv.parent.subscription_details.subscription))
    local row = sub_id and db.query("SELECT * FROM billing_subscriptions WHERE stripe_subscription_id = ?", sub_id)[1]
    if not row then return "ignored" end
    local app = db.query("SELECT * FROM billing_apps WHERE id = ?", row.app_id)[1]
    if Settings.resolve(app).refund_policy ~= "revoke" then return true end
    local ok, cerr = s:_request("DELETE", "/subscriptions/" .. sub_id)
    if not ok then error("could not cancel the subscription: " .. tostring(cerr)) end
    return true -- customer.subscription.deleted follows and ends access
end

local HANDLERS = {
    ["checkout.session.completed"] = fulfil_session,
    ["checkout.session.async_payment_succeeded"] = fulfil_session,
    ["customer.subscription.updated"] = function(o) return sync_subscription(o, false) end,
    ["customer.subscription.deleted"] = function(o) return sync_subscription(o, true) end,
    ["charge.refunded"] = refunded,
    ["account.updated"] = function(o)
        if not db.query("SELECT 1 FROM billing_connect_accounts WHERE stripe_account_id = ?", o.id)[1] then
            return "ignored"
        end
        save_account(o)
        return true
    end,
}

--- Handle a verified event. @return true (handled) | "ignored"; raises on failure (Stripe retries)
function Pay.handle(event)
    local h = HANDLERS[event.type]
    if not h then return "ignored" end
    return h(event.data and event.data.object or {})
end

Pay.present_account = present_account

return Pay
