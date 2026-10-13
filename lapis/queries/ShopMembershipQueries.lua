-- luacheck: max line length 140
--[[
    Shop VIP price-lock membership
    ==============================
    Rules (prices, cap, lock, refund, credit maths) live in lib/shop-membership.lua.
    This module does the database + Stripe work:

      settings / offer        per-namespace settings, public offer with the REAL founding count
      startCheckout           reserve a founding spot under a lock, Stripe Checkout (mode=subscription)
      Stripe events           session completed/expired, invoice.paid, subscription updated/deleted
                              (called from ShopStripeQueries inside its one-transaction ledger)
      sign-in                 emailed one-time link → 30-day session (sha256 hashes only)
      credits                 reserve at checkout, use when paid, release when not; VIP fee refund
      early access, waitlist

    Memberships are mirrored into billing_subscriptions (customer_id → customers)
    under a "workstation-vip" billing_apps row so they show in the billing admin.

    Founding count = founding memberships that have joined (paid) + pending
    founding checkouts whose reservation has not expired. Nothing else.
]]

local db = require("lapis.db")
local unpack = unpack or table.unpack -- luacheck: ignore 113 143
local Global = require("helper.global")
local U = require("lib.shop-util")
local R = require("lib.shop-membership")

local Q = {}

local VIP_SOURCE = "workstation-shop-vip"
local RESERVE_MINUTES = 32      -- ≥ the Stripe session lifetime below, so a live session always holds its spot
local SESSION_MINUTES = 31      -- Stripe allows 30 min – 24 h
local LINK_MINUTES = 15
local SESSION_DAYS = 30
local MAX_LINKS_PER_HOUR = 5
local CLOSE_DAYS = 90
local MEMBER_STATUSES = { active = true, past_due = true }

Q.VIP_SOURCE = VIP_SOURCE

local function nz(v) return U.nz(v) end

local function id_of(v)
    v = nz(v)
    if type(v) == "table" then return nz(v.id) end
    return v
end

local function ts(unix)
    unix = tonumber(unix)
    if not unix then return db.NULL end
    return db.raw(("to_timestamp(%d)"):format(math.floor(unix)))
end

-- ---------------------------------------------------------------------------
-- settings + offer
-- ---------------------------------------------------------------------------

function Q.settings(ns_id)
    local row = db.query("SELECT * FROM shop_membership_settings WHERE namespace_id = ?", ns_id)[1]
    local s = R.settings(row)
    s.billing_app_id = row and row.billing_app_id or nil
    return s
end

function Q.updateSettings(ns_id, body)
    local fields, err = R.validate_update(body)
    if not fields then return nil, U.err(400, "VALIDATION_ERROR", err) end
    db.query("INSERT INTO shop_membership_settings (namespace_id) VALUES (?) ON CONFLICT (namespace_id) DO NOTHING", ns_id)
    if next(fields) then
        fields.updated_at = db.raw("NOW()")
        db.update("shop_membership_settings", fields, { namespace_id = ns_id })
    end
    return Q.adminSettings(ns_id)
end

function Q.foundingTaken(ns_id)
    return db.query([[
        SELECT COUNT(*)::int AS n FROM shop_memberships
         WHERE namespace_id = ? AND tier = 'founding'
           AND (joined_at IS NOT NULL OR (status = 'pending' AND reserve_expires_at > NOW()))
    ]], ns_id)[1].n
end

local function price_view(p)
    return {
        month = { net_minor = p.month.net_minor, vat_minor = p.month.vat_minor, gross_minor = p.month.gross_minor },
        year = { net_minor = p.year.net_minor, vat_minor = p.year.vat_minor, gross_minor = p.year.gross_minor },
        months_free_yearly = p.months_free_yearly,
    }
end

--- Public offer: real prices, real founding count, the settings customers rely on.
function Q.offer(ns_id)
    local s = Q.settings(ns_id)
    local taken = Q.foundingTaken(ns_id)
    local tier = R.tier_for(s, taken)
    return {
        enabled = s.enabled,
        currency = "GBP",
        vat_rate = s.vat_rate,
        tier = tier,
        price = price_view(R.prices(s, tier)),
        founding = {
            cap = s.founding_cap,
            taken = taken,
            spots_left = R.spots_left(s, taken),
            price = price_view(R.prices(s, "founding")),
        },
        standard_price = price_view(R.prices(s, "standard")),
        uplift_pct = s.uplift_pct,
        lock_days = s.lock_days,
        refund_threshold_minor = s.refund_threshold_minor,
        credit_expiry_days = s.credit_expiry_days,
        early_access_hours = s.early_access_hours,
        long_lead_days = s.long_lead_days,
        terms_version = s.terms_version,
    }
end

function Q.adminSettings(ns_id)
    local s = Q.settings(ns_id)
    local out = {}
    for k in pairs(R.DEFAULTS) do out[k] = s[k] end
    out.offer = Q.offer(ns_id)
    return out
end

-- ---------------------------------------------------------------------------
-- billing mirror (customers, billing_apps, billing_plans, billing_subscriptions)
-- ---------------------------------------------------------------------------

local function billing_app(ns_id)
    local app = db.query([[SELECT id FROM billing_apps WHERE namespace_id = ? AND slug = 'workstation-vip'
                            AND deleted_at IS NULL LIMIT 1]], ns_id)[1]
    if app then return app.id end
    local mode = require("lib.payment-provider").stripe_mode()
    return db.query([[
        INSERT INTO billing_apps (uuid, namespace_id, name, slug, kind, mode, publishable_key, settings, active,
                                  created_at, updated_at)
        VALUES (?, ?, 'Workstation VIP membership', 'workstation-vip', 'web', ?, ?, '{}'::jsonb, true, NOW(), NOW())
        RETURNING id
    ]], Global.generateUUID(), ns_id, mode, "pk_shopvip_" .. U.token(18))[1].id
end

local function billing_plan(ns_id, app_id, m)
    local key = "vip-" .. m.tier .. "-" .. m.billing_interval
    local plan = db.query([[SELECT id, amount FROM billing_plans WHERE app_id = ? AND plan_key = ? AND deleted_at IS NULL]],
        app_id, key)[1]
    if plan then
        if tonumber(plan.amount) ~= tonumber(m.net_minor) then
            db.query("UPDATE billing_plans SET amount = ?, updated_at = NOW() WHERE id = ?", m.net_minor, plan.id)
        end
        return plan.id
    end
    return db.query([[
        INSERT INTO billing_plans (uuid, namespace_id, app_id, plan_key, name, description, plan_type, amount, currency,
                                   billing_interval, interval_count, purchase_type, is_public, active, metadata,
                                   created_at, updated_at)
        VALUES (?, ?, ?, ?, ?, 'Sold on the shop (shop_memberships); amount is ex VAT', 'subscription', ?, 'gbp',
                ?, 1, 'recurring', false, true, '{}'::jsonb, NOW(), NOW())
        RETURNING id
    ]], Global.generateUUID(), ns_id, app_id, key,
        "VIP membership (" .. m.tier .. ", " .. (m.billing_interval == "year" and "yearly" or "monthly") .. ")",
        m.net_minor, m.billing_interval)[1].id
end

local function customer_for(ns_id, email)
    local c = db.query("SELECT id FROM customers WHERE namespace_id = ? AND lower(email) = lower(?) LIMIT 1", ns_id, email)[1]
    if c then return c.id end
    local ok, res = pcall(db.query, [[
        INSERT INTO customers (uuid, namespace_id, email, created_at, updated_at) VALUES (?, ?, ?, NOW(), NOW()) RETURNING id
    ]], Global.generateUUID(), ns_id, email)
    if ok and res[1] then return res[1].id end
    c = db.query("SELECT id FROM customers WHERE namespace_id = ? AND lower(email) = lower(?) LIMIT 1", ns_id, email)[1]
    return c and c.id or nil
end

local STRIPE_TO_BILLING = {
    active = "active", past_due = "past_due", canceled = "canceled", expired = "incomplete_expired",
}

--- Create or update the billing_subscriptions mirror of a membership row.
local function mirror(m)
    local ok, err = pcall(function()
        local app_id = billing_app(m.namespace_id)
        local plan_id = billing_plan(m.namespace_id, app_id, m)
        local customer_id = tonumber(m.customer_id) or customer_for(m.namespace_id, m.email)
        local status = STRIPE_TO_BILLING[m.status] or "incomplete"
        if nz(m.billing_subscription_id) then
            db.query([[
                UPDATE billing_subscriptions SET status = ?, current_period_end = ?, cancel_at_period_end = ?,
                       canceled_at = ?, stripe_subscription_id = COALESCE(stripe_subscription_id, ?),
                       stripe_customer_id = COALESCE(stripe_customer_id, ?), updated_at = NOW()
                 WHERE id = ?
            ]], status, m.current_period_end or db.NULL, m.cancel_at_period_end == true, m.canceled_at or db.NULL,
                m.stripe_subscription_id or db.NULL, m.stripe_customer_id or db.NULL, m.billing_subscription_id)
        else
            local row = db.query([[
                INSERT INTO billing_subscriptions (uuid, namespace_id, app_id, plan_id, customer_id, provider, source, status,
                                                   stripe_subscription_id, stripe_customer_id, current_period_start,
                                                   current_period_end, cancel_at_period_end, metadata, created_at, updated_at)
                VALUES (?, ?, ?, ?, ?, 'stripe', 'stripe', ?, ?, ?, NOW(), ?, ?, ?::jsonb, NOW(), NOW())
                RETURNING id
            ]], Global.generateUUID(), m.namespace_id, app_id, plan_id, customer_id, status,
                m.stripe_subscription_id or db.NULL, m.stripe_customer_id or db.NULL, m.current_period_end or db.NULL,
                m.cancel_at_period_end == true, U.enc({ shop_membership_uuid = m.uuid, tier = m.tier }))[1]
            db.query("UPDATE shop_memberships SET billing_subscription_id = ?, customer_id = ? WHERE id = ?",
                row.id, customer_id or db.NULL, m.id)
        end
    end)
    if not ok then ngx.log(ngx.WARN, "[shop-vip] billing mirror failed for ", tostring(m.uuid), ": ", tostring(err)) end
end

-- ---------------------------------------------------------------------------
-- joining
-- ---------------------------------------------------------------------------

local function active_membership(ns_id, email)
    return db.query([[
        SELECT * FROM shop_memberships WHERE namespace_id = ? AND lower(email) = lower(?)
           AND status IN ('active', 'past_due') ORDER BY joined_at DESC NULLS LAST LIMIT 1
    ]], ns_id, email)[1]
end

local function recurring_item(name, amount, interval)
    return {
        price_data = { currency = "gbp", unit_amount = amount, recurring = { interval = interval },
                       product_data = { name = name } },
        quantity = 1,
    }
end

--- POST /membership/checkout
-- body: { email, interval: month|year, accept_terms: true, terms_version, success_url, cancel_url }
function Q.startCheckout(ns_id, body)
    body = type(body) == "table" and body or {}
    local s = Q.settings(ns_id)
    if not s.enabled then return nil, U.err(409, "MEMBERSHIP_CLOSED", "VIP membership is not open yet") end
    local email = R.email(body.email)
    if not email then return nil, U.err(400, "VALIDATION_ERROR", "Please enter a valid email address") end
    local interval = body.interval
    if not R.INTERVALS[interval] then return nil, U.err(400, "VALIDATION_ERROR", "interval must be month or year") end
    if body.accept_terms ~= true then
        return nil, U.err(400, "TERMS_NOT_ACCEPTED", "Please read and accept the membership terms")
    end
    if body.terms_version ~= s.terms_version then
        return nil, U.err(409, "TERMS_CHANGED", "The membership terms have been updated — please read them again")
    end
    if not U.url_allowed(body.success_url) or not U.url_allowed(body.cancel_url) then
        return nil, U.err(400, "INVALID_REDIRECT_URL", "success_url and cancel_url must start with an allowed origin")
    end
    if active_membership(ns_id, email) then
        return nil, U.err(409, "ALREADY_MEMBER", "This email already has an active membership — sign in instead")
    end
    local stripe, serr = require("lib.payment-provider").get_stripe()
    if not stripe then
        ngx.log(ngx.ERR, "[shop-vip] ", tostring(serr))
        return nil, U.err(503, "PAYMENTS_DISABLED", "Online payment is not available right now")
    end

    -- Reserve the spot: the count and the insert happen under one per-namespace lock, so the
    -- (cap+1)th person can never be given the founding price, however many check out at once.
    local m = U.tx(function()
        db.query("SELECT pg_advisory_xact_lock(hashtext('shop_vip_cap_' || ?))", tostring(ns_id))
        db.query([[UPDATE shop_memberships SET status = 'abandoned', updated_at = NOW()
                    WHERE namespace_id = ? AND status = 'pending' AND reserve_expires_at <= NOW()]], ns_id)
        local tier = R.tier_for(s, Q.foundingTaken(ns_id))
        local price = R.prices(s, tier)[interval]
        return db.query([[
            INSERT INTO shop_memberships (uuid, namespace_id, email, tier, billing_interval, net_minor, vat_minor, status,
                                          reserve_expires_at, terms_version, terms_accepted_at, created_at, updated_at)
            VALUES (?, ?, ?, ?, ?, ?, ?, 'pending', NOW() + (? || ' minutes')::interval, ?, NOW(), NOW(), NOW())
            RETURNING *
        ]], Global.generateUUID(), ns_id, email, tier, interval, price.net_minor, price.vat_minor,
            tostring(RESERVE_MINUTES), s.terms_version)[1]
    end)

    local label = "Workstation VIP membership" .. (m.tier == "founding" and " (founding member)" or "")
    local meta = { membership_uuid = m.uuid, namespace_id = tostring(ns_id), source = VIP_SOURCE }
    local items = { recurring_item(label, tonumber(m.net_minor), interval) }
    if tonumber(m.vat_minor) > 0 then
        items[2] = recurring_item("VAT (" .. math.floor(s.vat_rate * 100 + 0.5) .. "%)", tonumber(m.vat_minor), interval)
    end
    local session, stripe_err = stripe:create_checkout_session({
        mode = "subscription",
        success_url = body.success_url,
        cancel_url = body.cancel_url,
        line_items = items,
        customer_email = email,
        client_reference_id = m.uuid,
        metadata = meta,
        subscription_data = { metadata = meta },
        billing_address_collection = "required",
        tax_id_collection = { enabled = true },
        expires_at = os.time() + SESSION_MINUTES * 60,
        idempotency_key = "shop-vip-" .. m.uuid,
    })
    if not session or not session.url then
        ngx.log(ngx.ERR, "[shop-vip] Stripe session failed for ", m.uuid, ": ", tostring(stripe_err))
        db.query("UPDATE shop_memberships SET status = 'abandoned', updated_at = NOW() WHERE id = ?", m.id)
        return nil, U.err(502, "PAYMENT_PROVIDER_ERROR", "Could not start checkout — please try again")
    end
    db.query("UPDATE shop_memberships SET stripe_session_id = ?, updated_at = NOW() WHERE id = ?", session.id, m.id)
    return {
        checkout_url = session.url, membership_uuid = m.uuid, tier = m.tier, interval = interval,
        net_minor = tonumber(m.net_minor), vat_minor = tonumber(m.vat_minor),
        gross_minor = tonumber(m.net_minor) + tonumber(m.vat_minor),
    }
end

-- ---------------------------------------------------------------------------
-- Stripe events (run inside ShopStripeQueries' transaction)
-- ---------------------------------------------------------------------------

function Q.isVipObject(obj)
    local meta = type(obj) == "table" and obj.metadata or nil
    if type(meta) == "table" and meta.source == VIP_SOURCE then return true end
    local sd = type(obj) == "table" and obj.subscription_details or nil
    return type(sd) == "table" and type(sd.metadata) == "table" and sd.metadata.source == VIP_SOURCE
end

local function membership_by(uuid, sub_id)
    local row
    if nz(uuid) then row = db.query("SELECT * FROM shop_memberships WHERE uuid = ? FOR UPDATE", uuid)[1] end
    if not row and nz(sub_id) then
        row = db.query("SELECT * FROM shop_memberships WHERE stripe_subscription_id = ? FOR UPDATE", sub_id)[1]
    end
    return row
end

local function reload(id) return db.query("SELECT * FROM shop_memberships WHERE id = ?", id)[1] end

local function record_lead(m, note)
    pcall(function()
        require("queries.ShopLeadQueries").safeUpsert(m.namespace_id, { email = m.email, source = "shop_vip", note = note })
    end)
end

--- Make a membership active (first payment). Idempotent.
local function activate(m, sub_id, customer_id)
    if m.joined_at then
        if nz(sub_id) and not nz(m.stripe_subscription_id) then
            db.query("UPDATE shop_memberships SET stripe_subscription_id = ? WHERE id = ?", sub_id, m.id)
        end
        return reload(m.id)
    end
    db.query([[
        UPDATE shop_memberships SET status = 'active', joined_at = NOW(), reserve_expires_at = NULL,
               stripe_subscription_id = COALESCE(?, stripe_subscription_id),
               stripe_customer_id = COALESCE(?, stripe_customer_id), updated_at = NOW()
         WHERE id = ?
    ]], sub_id or db.NULL, customer_id or db.NULL, m.id)
    m = reload(m.id)
    record_lead(m, "Joined VIP membership (" .. m.tier .. ", " .. m.billing_interval .. "ly)")
    return m
end

function Q.onSessionCompleted(session)
    local meta = type(session.metadata) == "table" and session.metadata or {}
    local m = membership_by(nz(meta.membership_uuid) or nz(session.client_reference_id), id_of(session.subscription))
    if not m then return nil end
    local ps = nz(session.payment_status)
    if ps == "paid" or ps == "no_payment_required" then
        m = activate(m, id_of(session.subscription), id_of(session.customer))
    else
        db.query([[UPDATE shop_memberships SET stripe_subscription_id = COALESCE(?, stripe_subscription_id),
                   stripe_customer_id = COALESCE(?, stripe_customer_id), updated_at = NOW() WHERE id = ?]],
            id_of(session.subscription) or db.NULL, id_of(session.customer) or db.NULL, m.id)
        m = reload(m.id)
    end
    mirror(m)
    return m
end

function Q.onSessionExpired(session)
    local meta = type(session.metadata) == "table" and session.metadata or {}
    local m = membership_by(nz(meta.membership_uuid) or nz(session.client_reference_id), nil)
    if m and m.status == "pending" then
        db.query("UPDATE shop_memberships SET status = 'abandoned', updated_at = NOW() WHERE id = ?", m.id)
    end
    return m
end

--- invoice.paid: count the fee (ex VAT) once per invoice, keep the period end current.
function Q.onInvoicePaid(invoice)
    local sd = type(invoice.subscription_details) == "table" and invoice.subscription_details or {}
    local meta = type(sd.metadata) == "table" and sd.metadata or {}
    local m = membership_by(nz(meta.membership_uuid), id_of(invoice.subscription))
    if not m then return nil end
    if nz(invoice.id) and m.last_invoice_id == invoice.id then return m end
    if not m.joined_at then m = activate(m, id_of(invoice.subscription), id_of(invoice.customer)) end
    local paid = tonumber(invoice.amount_paid) or 0
    local period_end
    local lines = type(invoice.lines) == "table" and invoice.lines.data or nil
    if type(lines) == "table" and type(lines[1]) == "table" and type(lines[1].period) == "table" then
        period_end = lines[1].period["end"]
    end
    db.query([[
        UPDATE shop_memberships SET fees_paid_net_minor = fees_paid_net_minor + ?, last_invoice_id = ?,
               status = CASE WHEN status IN ('pending', 'past_due') THEN 'active' ELSE status END,
               current_period_end = COALESCE(?, current_period_end), updated_at = NOW()
         WHERE id = ?
    ]], paid > 0 and tonumber(m.net_minor) or 0, invoice.id or db.NULL, ts(period_end), m.id)
    m = reload(m.id)
    mirror(m)
    return m
end

local SUB_STATUS = {
    active = "active", trialing = "active", past_due = "past_due", unpaid = "past_due",
    canceled = "canceled", incomplete_expired = "expired",
}

function Q.onSubscriptionChanged(sub)
    local meta = type(sub.metadata) == "table" and sub.metadata or {}
    local m = membership_by(nz(meta.membership_uuid), nz(sub.id))
    if not m then return nil end
    local status = SUB_STATUS[sub.status]
    if not status or (status == "active" and not m.joined_at) then status = m.status end
    local period_end = sub.current_period_end
    if not period_end and type(sub.items) == "table" and type(sub.items.data) == "table" and sub.items.data[1] then
        period_end = sub.items.data[1].current_period_end
    end
    db.query([[
        UPDATE shop_memberships SET status = ?, stripe_subscription_id = COALESCE(stripe_subscription_id, ?),
               current_period_end = COALESCE(?, current_period_end), cancel_at_period_end = ?,
               canceled_at = COALESCE(?, canceled_at), updated_at = NOW()
         WHERE id = ?
    ]], status, sub.id or db.NULL, ts(period_end), sub.cancel_at_period_end == true, ts(sub.canceled_at), m.id)
    m = reload(m.id)
    mirror(m)
    return m
end

-- ---------------------------------------------------------------------------
-- sign-in (emailed link → session)
-- ---------------------------------------------------------------------------

local function html_escape(s)
    return (tostring(s):gsub("[&<>\"']", { ["&"] = "&amp;", ["<"] = "&lt;", [">"] = "&gt;", ['"'] = "&quot;", ["'"] = "&#39;" }))
end

--- Send one email: through the workspace's own mail server when it has one (Workstation's sender), else the
-- deployment's. Sent from our own timer with sync = true, because Mail.send's built-in async mode drops
-- opts.smtp (a workspace's mail would go through the deployment's server). Returns true when queued.
local function send_mail(ns_id, to, subject, html)
    local Mail = require("helper.mail")
    local NamespaceMail = require("helper.namespace-mail")
    local smtp = NamespaceMail.smtp(ns_id)
    if smtp and not NamespaceMail.hostOk(smtp.host) then smtp = nil end
    if not smtp and not Mail.isConfigured() then
        ngx.log(ngx.ERR, "[shop-vip] no SMTP configured (workspace or deployment) — email to ", to, " not sent")
        return false
    end
    local msg = {
        to = to, subject = subject, html = html, smtp = smtp, sync = true, wrap_in_layout = true,
        from_email = smtp and smtp.from_email or nil,
        from_name = smtp and smtp.from_name or "Workstation",
        reply_to = smtp and smtp.reply_to or nil,
        data = { app_name = "Workstation" },
    }
    local ok, terr = ngx.timer.at(0, function(premature)
        if premature then return end
        local sent, err = Mail.send(msg)
        if not sent then ngx.log(ngx.ERR, "[shop-vip] email to ", to, " failed: ", tostring(err)) end
    end)
    if not ok then
        ngx.log(ngx.ERR, "[shop-vip] could not queue email: ", tostring(terr))
        return false
    end
    return true -- ngx.timer.at returns a handle, not true, on success
end

--- Anyone with a membership record (any status but pending/abandoned) or a credit can sign in.
local function may_sign_in(ns_id, email)
    local r = db.query([[
        SELECT (EXISTS (SELECT 1 FROM shop_memberships WHERE namespace_id = ? AND lower(email) = ?
                        AND status NOT IN ('pending', 'abandoned'))
             OR EXISTS (SELECT 1 FROM shop_credits WHERE namespace_id = ? AND lower(email) = ? AND status = 'available'))
             AS ok
    ]], ns_id, email, ns_id, email)[1]
    return r and r.ok == true
end

local function deactivation_row(ns_id, email, status)
    return db.query([[
        SELECT uuid, status, deactivated_at, close_at, closed_at, reactivated_at
          FROM shop_account_deactivations
         WHERE namespace_id = ? AND lower(email) = lower(?) AND status = ?
         ORDER BY id DESC LIMIT 1
    ]], ns_id, email, status)[1]
end

local function deactivation_payload(row)
    if not row then return U.null end
    return {
        status = row.status,
        deactivated_at = row.deactivated_at or U.null,
        close_at = row.close_at or U.null,
        closed_at = row.closed_at or U.null,
        close_days = CLOSE_DAYS,
    }
end

--- Closed accounts cannot sign in again. Pending deactivation is cleared on the next successful sign-in.
function Q.assertCanSignIn(ns_id, email)
    if deactivation_row(ns_id, email, "closed") then
        return nil, U.err(403, "ACCOUNT_CLOSED",
            "This shop account was closed. Email privacy@workstation.co.uk if you need help.")
    end
    return true
end

function Q.reactivateIfPending(ns_id, email)
    db.query([[
        UPDATE shop_account_deactivations
           SET status = 'reactivated', reactivated_at = NOW(), updated_at = NOW()
         WHERE namespace_id = ? AND lower(email) = lower(?) AND status = 'pending'
    ]], ns_id, email)
end

local function revoke_tokens(ns_id, email, keep_session_hash)
    if keep_session_hash then
        db.query([[
            DELETE FROM shop_member_tokens
             WHERE namespace_id = ? AND lower(email) = lower(?)
               AND NOT (kind = 'session' AND token_hash = ?)
        ]], ns_id, email, keep_session_hash)
    else
        db.query("DELETE FROM shop_member_tokens WHERE namespace_id = ? AND lower(email) = lower(?)", ns_id, email)
    end
end

local function close_one(row)
    db.query("BEGIN")
    local ok, err = pcall(function()
        revoke_tokens(row.namespace_id, row.email, nil)
        db.query([[
            UPDATE shop_credits SET status = 'void', updated_at = NOW()
             WHERE namespace_id = ? AND lower(email) = lower(?) AND status = 'available'
        ]], row.namespace_id, row.email)
        db.query("DELETE FROM shop_waitlist WHERE namespace_id = ? AND lower(email) = lower(?)",
            row.namespace_id, row.email)
        db.query([[
            UPDATE shop_account_deactivations
               SET status = 'closed', closed_at = NOW(), updated_at = NOW()
             WHERE id = ? AND status = 'pending'
        ]], row.id)
    end)
    if ok then
        db.query("COMMIT")
        return true
    end
    pcall(function() db.query("ROLLBACK") end)
    ngx.log(ngx.ERR, "[shop-account] close failed for ", tostring(row.email), ": ", tostring(err))
    return false
end

--- One-time sign-in link token for an email (hash stored). Used by the emailed link and by
-- Google / Apple shop sign-in (ShopCustomerAuthQueries), which vouch for the email themselves.
function Q.issueSignInLink(ns_id, email)
    local ok, err = Q.assertCanSignIn(ns_id, email)
    if not ok then return nil, err end
    local token = U.token(32)
    db.query([[INSERT INTO shop_member_tokens (namespace_id, email, kind, token_hash, expires_at)
               VALUES (?, ?, 'link', ?, NOW() + (? || ' minutes')::interval)]],
        ns_id, email, U.sha256_hex(token), tostring(LINK_MINUTES))
    return token
end

--- POST /member/login. Always answers the same way (no "is this a member?" oracle).
-- Returns { sent = bool } — `sent` is for logs/tests only and is NOT returned to the browser.
function Q.requestLogin(ns_id, body)
    body = type(body) == "table" and body or {}
    local email = R.email(body.email)
    if not email then return nil, U.err(400, "VALIDATION_ERROR", "Please enter a valid email address") end
    if not may_sign_in(ns_id, email) then return { sent = false } end
    local recent = db.query([[SELECT COUNT(*)::int AS n FROM shop_member_tokens WHERE namespace_id = ? AND email = ?
                               AND kind = 'link' AND created_at > NOW() - interval '1 hour']], ns_id, email)[1].n
    if recent >= MAX_LINKS_PER_HOUR then return { sent = false, throttled = true } end
    local base = U.env("SHOP_PUBLIC_URL")
    if not base then
        ngx.log(ngx.ERR, "[shop-vip] SHOP_PUBLIC_URL is not set — cannot build sign-in links")
        return { sent = false }
    end
    local token, terr = Q.issueSignInLink(ns_id, email)
    if not token then return { sent = false, blocked = terr and terr.code or true } end
    local link = base:gsub("/+$", "") .. "/members/verify?t=" .. token
    local ok = send_mail(ns_id, email, "Your Workstation members sign-in link",
        "<p>Use this link to sign in to your Workstation VIP membership. It works once and expires in "
            .. LINK_MINUTES .. " minutes.</p><p><a href=\"" .. html_escape(link) .. "\">Sign in to Workstation</a></p>"
            .. "<p>If you didn't ask for this, you can ignore this email.</p>")
    if not ok then return { sent = false } end
    return { sent = true }
end

--- POST /member/verify { token } → { session_token, email }
function Q.verifyLink(ns_id, body)
    local token = type(body) == "table" and nz(body.token) or nil
    if not token or #token < 20 or #token > 200 then return nil, U.err(400, "INVALID_LINK", "This sign-in link is not valid") end
    local row = db.query([[
        UPDATE shop_member_tokens SET used_at = NOW()
         WHERE namespace_id = ? AND token_hash = ? AND kind = 'link' AND used_at IS NULL AND expires_at > NOW()
        RETURNING email
    ]], ns_id, U.sha256_hex(token))[1]
    if not row then
        return nil, U.err(410, "LINK_EXPIRED", "This sign-in link has expired or was already used — ask for a new one")
    end
    local ok, err = Q.assertCanSignIn(ns_id, row.email)
    if not ok then return nil, err end
    Q.reactivateIfPending(ns_id, row.email)
    local session = U.token(32)
    db.query([[INSERT INTO shop_member_tokens (namespace_id, email, kind, token_hash, expires_at)
               VALUES (?, ?, 'session', ?, NOW() + (? || ' days')::interval)]],
        ns_id, row.email, U.sha256_hex(session), tostring(SESSION_DAYS))
    db.query("DELETE FROM shop_member_tokens WHERE expires_at < NOW() - interval '7 days'")
    return { session_token = session, email = row.email, expires_in_days = SESSION_DAYS }
end

--- Resolve X-Member-Token → { email, active, membership, early_access_hours } or nil.
function Q.memberFromSession(ns_id, token)
    if not nz(token) or #token < 20 or #token > 200 then return nil end
    local row = db.query([[SELECT email FROM shop_member_tokens WHERE namespace_id = ? AND token_hash = ?
                            AND kind = 'session' AND expires_at > NOW()]], ns_id, U.sha256_hex(token))[1]
    if not row then return nil end
    local m = active_membership(ns_id, row.email)
    local s = Q.settings(ns_id)
    return {
        email = row.email,
        active = m ~= nil and MEMBER_STATUSES[m.status] == true,
        membership = m,
        early_access_hours = s.early_access_hours,
        lock_days = s.lock_days,
    }
end

function Q.logout(ns_id, token)
    if nz(token) then
        db.query("DELETE FROM shop_member_tokens WHERE namespace_id = ? AND token_hash = ? AND kind = 'session'",
            ns_id, U.sha256_hex(token))
    end
    return { signed_out = true }
end

-- ---------------------------------------------------------------------------
-- credits
-- ---------------------------------------------------------------------------

function Q.availableCredits(ns_id, email)
    return db.query([[
        SELECT id, uuid, amount_minor, min_order_minor, source, reason, expires_at, created_at FROM shop_credits
         WHERE namespace_id = ? AND lower(email) = lower(?) AND status = 'available'
           AND (expires_at IS NULL OR expires_at > NOW())
         ORDER BY expires_at NULLS LAST, id
    ]], ns_id, email)
end

--- Reserve the applied credits for a pending order (inside the checkout transaction).
-- A partly used credit is split: the used part is reserved, the rest stays available.
function Q.reserveCredits(ns_id, order_id, applied)
    for _, a in ipairs(applied) do
        if a.amount_minor < a.whole_minor then
            local c = db.query("SELECT * FROM shop_credits WHERE id = ? FOR UPDATE", a.id)[1]
            db.query("UPDATE shop_credits SET amount_minor = amount_minor - ?, updated_at = NOW() WHERE id = ?",
                a.amount_minor, a.id)
            db.query([[
                INSERT INTO shop_credits (uuid, namespace_id, email, amount_minor, min_order_minor, source, reason, status,
                                          reserved_order_id, membership_id, crm_lead_id, expires_at, created_by)
                VALUES (?, ?, ?, ?, 0, ?, ?, 'reserved', ?, ?, ?, ?, 'split')
            ]], Global.generateUUID(), ns_id, c.email, a.amount_minor, c.source,
                "Part of credit " .. c.uuid, order_id, c.membership_id or db.NULL, c.crm_lead_id or db.NULL,
                c.expires_at or db.NULL)
        else
            db.query([[UPDATE shop_credits SET status = 'reserved', reserved_order_id = ?, updated_at = NOW()
                        WHERE id = ? AND status = 'available']], order_id, a.id)
        end
    end
end

function Q.useCredits(order_id)
    db.query([[UPDATE shop_credits SET status = 'used', used_order_id = ?, updated_at = NOW()
                WHERE reserved_order_id = ? AND status = 'reserved']], order_id, order_id)
end

function Q.releaseCredits(order_id)
    db.query([[UPDATE shop_credits SET status = 'available', reserved_order_id = NULL, updated_at = NOW()
                WHERE reserved_order_id = ? AND status = 'reserved']], order_id)
end

--- On a paid order: if the buyer is a member and the order qualifies, turn the fees they've paid
-- (not yet credited) into credit for a later order. Runs inside the paid-order transaction.
function Q.maybeIssueRefundCredit(order)
    local email = nz(order.email)
    if not email then return nil end
    local m = db.query([[
        SELECT * FROM shop_memberships WHERE namespace_id = ? AND lower(email) = lower(?)
           AND status IN ('active', 'past_due') ORDER BY joined_at DESC LIMIT 1 FOR UPDATE
    ]], order.namespace_id, email)[1]
    if not m then return nil end
    local s = Q.settings(order.namespace_id)
    -- What the order was worth before any credit (credit doesn't stop it qualifying).
    local qualifying = (tonumber(order.subtotal_minor) or 0) + (tonumber(order.credit_minor) or 0)
    local amount = R.refund_credit(s, qualifying, m.fees_paid_net_minor, m.fees_credited_net_minor)
    if amount <= 0 then return nil end
    db.query([[
        INSERT INTO shop_credits (uuid, namespace_id, email, amount_minor, min_order_minor, source, reason, status,
                                  earned_order_id, membership_id, expires_at, created_by)
        VALUES (?, ?, ?, ?, 0, 'vip_refund', ?, 'available', ?, ?, NOW() + (? || ' days')::interval, 'system')
    ]], Global.generateUUID(), order.namespace_id, m.email, amount,
        "VIP membership fees refunded as credit (order " .. tostring(order.order_number) .. ")",
        order.id, m.id, tostring(s.credit_expiry_days))
    db.query("UPDATE shop_memberships SET fees_credited_net_minor = fees_credited_net_minor + ?, updated_at = NOW() WHERE id = ?",
        amount, m.id)
    record_lead(m, "VIP fee refund credit " .. U.money(amount) .. " (ex VAT) from order " .. tostring(order.order_number))
    return amount
end

-- ---------------------------------------------------------------------------
-- member area
-- ---------------------------------------------------------------------------

function Q.me(ns_id, member)
    local m = member.membership or db.query([[
        SELECT * FROM shop_memberships WHERE namespace_id = ? AND lower(email) = lower(?)
           AND status NOT IN ('pending', 'abandoned') ORDER BY joined_at DESC NULLS LAST LIMIT 1
    ]], ns_id, member.email)[1]
    local credits = {}
    for _, c in ipairs(Q.availableCredits(ns_id, member.email)) do
        credits[#credits + 1] = {
            uuid = c.uuid, amount_minor = tonumber(c.amount_minor), min_order_minor = tonumber(c.min_order_minor),
            source = c.source, reason = c.reason or U.null, expires_at = c.expires_at or U.null,
        }
    end
    local s = Q.settings(ns_id)
    local pending = deactivation_row(ns_id, member.email, "pending")
    return {
        email = member.email,
        active = member.active == true,
        membership = m and {
            uuid = m.uuid, tier = m.tier, interval = m.billing_interval, status = m.status,
            net_minor = tonumber(m.net_minor), vat_minor = tonumber(m.vat_minor),
            gross_minor = tonumber(m.net_minor) + tonumber(m.vat_minor),
            joined_at = m.joined_at or U.null, current_period_end = m.current_period_end or U.null,
            cancel_at_period_end = m.cancel_at_period_end == true,
            fees_paid_net_minor = tonumber(m.fees_paid_net_minor), fees_credited_net_minor = tonumber(m.fees_credited_net_minor),
        } or U.null,
        credits = U.arr(credits),
        lock_days = s.lock_days,
        refund_threshold_minor = s.refund_threshold_minor,
        early_access_hours = s.early_access_hours,
        deactivation = deactivation_payload(pending),
    }
end

--- POST /member/deactivate — schedule auto-close in 90 days. Keeps the current session so the
-- account page can show the scheduled date; other sessions/links for the email are revoked.
function Q.deactivate(ns_id, member, session_token)
    local email = R.email(member.email)
    if not email then return nil, U.err(400, "VALIDATION_ERROR", "No email on this session") end
    if deactivation_row(ns_id, email, "closed") then
        return nil, U.err(403, "ACCOUNT_CLOSED", "This shop account is already closed")
    end
    local pending = deactivation_row(ns_id, email, "pending")
    if not pending then
        db.query([[
            INSERT INTO shop_account_deactivations (uuid, namespace_id, email, status, deactivated_at, close_at)
            VALUES (?, ?, ?, 'pending', NOW(), NOW() + (? || ' days')::interval)
        ]], Global.generateUUID(), ns_id, email, tostring(CLOSE_DAYS))
        pending = deactivation_row(ns_id, email, "pending")
    end
    local keep = nz(session_token) and U.sha256_hex(session_token) or nil
    revoke_tokens(ns_id, email, keep)
    -- Best-effort: stop VIP renewals when the shopper is leaving.
    if member.membership and nz(member.membership.stripe_subscription_id)
        and not member.membership.cancel_at_period_end then
        pcall(function() Q.cancel(ns_id, member) end)
    end
    return Q.me(ns_id, member)
end

--- POST /member/reactivate — cancel a pending auto-close while still signed in.
function Q.reactivate(ns_id, member)
    local email = R.email(member.email)
    if not email then return nil, U.err(400, "VALIDATION_ERROR", "No email on this session") end
    if deactivation_row(ns_id, email, "closed") then
        return nil, U.err(403, "ACCOUNT_CLOSED", "This shop account was closed and cannot be reactivated here")
    end
    Q.reactivateIfPending(ns_id, email)
    return Q.me(ns_id, member)
end

--- Called from the shop reconciler timer: close every pending account past close_at.
function Q.closeDueAccounts()
    local rows = db.query([[
        SELECT id, namespace_id, email FROM shop_account_deactivations
         WHERE status = 'pending' AND close_at <= NOW()
         ORDER BY close_at ASC LIMIT 100
    ]])
    local closed, errors = 0, 0
    for _, row in ipairs(rows or {}) do
        if close_one(row) then closed = closed + 1 else errors = errors + 1 end
    end
    return { closed = closed, errors = errors, scanned = #(rows or {}) }
end

--- Cancel at the end of the paid period (Stripe), never mid-period.
function Q.cancel(ns_id, member)
    local m = member.membership
    if not m or not nz(m.stripe_subscription_id) then
        return nil, U.err(404, "NO_MEMBERSHIP", "There is no active membership to cancel")
    end
    if m.cancel_at_period_end then return Q.me(ns_id, member) end
    local stripe, serr = require("lib.payment-provider").get_stripe()
    if not stripe then
        ngx.log(ngx.ERR, "[shop-vip] cancel: ", tostring(serr))
        return nil, U.err(503, "PAYMENTS_DISABLED", "We couldn't reach the payment provider — please email us to cancel")
    end
    local res, err = stripe:cancel_subscription(m.stripe_subscription_id, true)
    if not res then
        ngx.log(ngx.ERR, "[shop-vip] cancel failed for ", m.uuid, ": ", tostring(err))
        return nil, U.err(502, "PAYMENT_PROVIDER_ERROR", "We couldn't cancel right now — please try again or email us")
    end
    db.query("UPDATE shop_memberships SET cancel_at_period_end = true, updated_at = NOW() WHERE id = ?", m.id)
    member.membership = reload(m.id)
    mirror(member.membership)
    record_lead(member.membership, "Cancelled VIP membership (ends at the end of the paid period)")
    return Q.me(ns_id, member)
end

--- Products in the members-only early window right now.
function Q.earlyAccess(ns_id, member)
    if not member or not member.active then return U.arr({}) end
    local Catalog = require("queries.ShopCatalogQueries")
    local rows = db.query([[
        SELECT p.id FROM shop_products p
         WHERE p.namespace_id = ? AND p.status = 'active' AND p.public_launch_at > NOW()
           AND p.public_launch_at - make_interval(hours => ?) <= NOW()
         ORDER BY p.public_launch_at
    ]], ns_id, member.early_access_hours)
    local ids = {}
    for i, r in ipairs(rows) do ids[i] = r.id end
    if #ids == 0 then return U.arr({}) end
    local map, out = Catalog.cardsByIds(ns_id, ids), {}
    for _, id in ipairs(ids) do if map[id] then out[#out + 1] = map[id] end end
    return U.arr(out)
end

-- ---------------------------------------------------------------------------
-- waitlist
-- ---------------------------------------------------------------------------

function Q.joinWaitlist(ns_id, slug, body, member)
    local email = R.email(type(body) == "table" and body.email or nil)
    if not email then return nil, U.err(400, "VALIDATION_ERROR", "Please enter a valid email address") end
    local p = db.query("SELECT id FROM shop_products WHERE namespace_id = ? AND slug = ? AND status = 'active'", ns_id, slug)[1]
    if not p then return nil, U.err(404, "PRODUCT_NOT_FOUND", "Product not found") end
    -- Priority only for a signed-in, active member joining with their own email.
    local is_member = member ~= nil and member.active == true and member.email == email
    db.query([[
        INSERT INTO shop_waitlist (namespace_id, product_id, email, is_member) VALUES (?, ?, ?, ?)
        ON CONFLICT (product_id, lower(email)) DO UPDATE SET is_member = shop_waitlist.is_member OR EXCLUDED.is_member
    ]], ns_id, p.id, email, is_member)
    return { joined = true, priority = is_member }
end

-- ---------------------------------------------------------------------------
-- admin: loyalty credits ("£X off your next order over £Y")
-- ---------------------------------------------------------------------------

local CREDIT_COLS = [[
    c.uuid, c.email, c.amount_minor, c.min_order_minor, c.source, c.reason, c.status, c.expires_at,
    c.created_by, c.created_at, c.updated_at, (c.expires_at IS NOT NULL AND c.expires_at <= NOW()) AS expired,
    eo.order_number AS earned_order_number, uo.order_number AS used_order_number, ro.order_number AS reserved_order_number,
    l.uuid AS crm_lead_uuid
]]
local CREDIT_FROM = [[
      FROM shop_credits c
      LEFT JOIN shop_orders eo ON eo.id = c.earned_order_id
      LEFT JOIN shop_orders uo ON uo.id = c.used_order_id
      LEFT JOIN shop_orders ro ON ro.id = c.reserved_order_id
      LEFT JOIN crm_leads l ON l.id = c.crm_lead_id
]]

local function credit_view(r)
    local out = {}
    for k, v in pairs(r) do out[k] = v end
    out.amount_minor = tonumber(r.amount_minor)
    out.min_order_minor = tonumber(r.min_order_minor)
    out.expired = r.expired == true
    out.total = nil
    for _, k in ipairs({ "reason", "expires_at", "created_by", "earned_order_number", "used_order_number",
                         "reserved_order_number", "crm_lead_uuid" }) do
        if out[k] == nil then out[k] = U.null end
    end
    return out
end

function Q.adminCredits(ns_id, params)
    params = params or {}
    local limit = U.clamp(U.int(params.limit, 25), 1, 200)
    local offset = math.max(0, U.int(params.offset, 0))
    local where, vals = { "c.namespace_id = ?" }, { ns_id }
    if nz(params.q) then
        where[#where + 1] = "(c.email ILIKE ? OR c.reason ILIKE ?)"
        local like = "%" .. tostring(params.q):sub(1, 200):gsub("[%%_\\]", "\\%0") .. "%"
        vals[#vals + 1] = like
        vals[#vals + 1] = like
    end
    if nz(params.status) then
        where[#where + 1] = "c.status = ?"
        vals[#vals + 1] = params.status
    end
    if nz(params.source) then
        where[#where + 1] = "c.source = ?"
        vals[#vals + 1] = params.source
    end
    vals[#vals + 1] = limit
    vals[#vals + 1] = offset
    local rows = db.query("SELECT " .. CREDIT_COLS .. ", COUNT(*) OVER() AS total " .. CREDIT_FROM .. " WHERE "
        .. table.concat(where, " AND ") .. " ORDER BY c.created_at DESC, c.id DESC LIMIT ? OFFSET ?", unpack(vals))
    local total = rows[1] and tonumber(rows[1].total) or 0
    local out = {}
    for i, r in ipairs(rows) do out[i] = credit_view(r) end
    return U.arr(out), { total = total, limit = limit, offset = offset }
end

local function credit_by_uuid(ns_id, uuid)
    local r = db.query("SELECT " .. CREDIT_COLS .. CREDIT_FROM .. " WHERE c.namespace_id = ? AND c.uuid = ?", ns_id, uuid)[1]
    return r and credit_view(r) or nil
end

--- Give a customer credit towards their next order. It is linked to their CRM lead (one per email), noted
-- there, and optionally emailed to them. They redeem it by signing in (emailed link) and paying with that email.
function Q.grantCredit(ns_id, body, actor)
    local s = Q.settings(ns_id)
    local c, err = R.validate_credit(body, s)
    if not c then return nil, U.err(400, "VALIDATION_ERROR", err) end
    local label = R.credit_label(c.amount_minor, c.min_order_minor, U.money)
    local lead = require("queries.ShopLeadQueries").safeUpsert(ns_id, {
        email = c.email, source = "shop_loyalty",
        note = "Loyalty credit given: " .. label .. " — " .. c.reason .. (actor and (" (by " .. actor .. ")") or ""),
    })
    local uuid = Global.generateUUID()
    db.query([[
        INSERT INTO shop_credits (uuid, namespace_id, email, amount_minor, min_order_minor, source, reason, status,
                                  crm_lead_id, expires_at, created_by)
        VALUES (?, ?, ?, ?, ?, 'loyalty', ?, 'available', ?, NOW() + (? || ' days')::interval, ?)
    ]], uuid, ns_id, c.email, c.amount_minor, c.min_order_minor, c.reason, lead and lead.id or db.NULL,
        tostring(c.expires_in_days), actor or db.NULL)
    local out = credit_by_uuid(ns_id, uuid)
    out.notified = false
    if c.notify then
        local base = U.env("SHOP_PUBLIC_URL")
        local members = base and (base:gsub("/+$", "") .. "/members") or nil
        out.notified = send_mail(ns_id, c.email, "You have credit with Workstation",
            "<p>Thank you for ordering with Workstation. We've added credit to your account: <strong>"
            .. html_escape(label) .. "</strong>.</p>"
            .. "<p>It's for orders paid with this email address and lasts until "
            .. html_escape(tostring(out.expires_at):sub(1, 10)) .. ".</p>"
            .. (members and ("<p>To use it, <a href=\"" .. html_escape(members) .. "\">sign in</a> with this email "
                .. "before you check out. It comes off your order automatically.</p>") or "")
            .. "<p>Credit can't be exchanged for cash.</p>")
    end
    return out
end

--- Cancel an unused credit. Reserved (mid-checkout) and used credits can't be voided.
function Q.voidCredit(ns_id, uuid, body, actor)
    local c = db.query("SELECT * FROM shop_credits WHERE namespace_id = ? AND uuid = ? FOR UPDATE", ns_id, uuid)[1]
    if not c then return nil, U.err(404, "NOT_FOUND", "Credit not found") end
    if c.status ~= "available" then
        return nil, U.err(409, "CREDIT_NOT_AVAILABLE", "Only unused credit can be cancelled (this one is " .. c.status .. ")")
    end
    local why = type(body) == "table" and type(body.reason) == "string" and body.reason:sub(1, 300) or nil
    db.query("UPDATE shop_credits SET status = 'void', updated_at = NOW() WHERE id = ?", c.id)
    require("queries.ShopLeadQueries").safeUpsert(ns_id, {
        email = c.email, source = "shop_loyalty",
        note = "Credit cancelled: " .. R.credit_label(c.amount_minor, c.min_order_minor, U.money)
            .. (why and (" — " .. why) or "") .. (actor and (" (by " .. actor .. ")") or ""),
    })
    return credit_by_uuid(ns_id, uuid)
end

function Q.adminWaitlist(ns_id, params)
    params = params or {}
    local where, vals = { "w.namespace_id = ?" }, { ns_id }
    if nz(params.product_uuid) then
        where[#where + 1] = "p.uuid = ?"
        vals[#vals + 1] = params.product_uuid
    end
    if not U.bool(params.include_notified, false) then where[#where + 1] = "w.notified_at IS NULL" end
    return U.arr(db.query([[
        SELECT w.email, w.is_member, w.created_at, w.notified_at, p.uuid AS product_uuid, p.sku, p.name AS product_name
          FROM shop_waitlist w JOIN shop_products p ON p.id = w.product_id
         WHERE ]] .. table.concat(where, " AND ") .. [[
         ORDER BY p.name, w.is_member DESC, w.created_at
         LIMIT 1000
    ]], unpack(vals)))
end

function Q.adminMembers(ns_id, params)
    params = params or {}
    local where, vals = { "namespace_id = ?", "status NOT IN ('pending', 'abandoned')" }, { ns_id }
    if nz(params.status) then
        where[#where + 1] = "status = ?"
        vals[#vals + 1] = params.status
    end
    if nz(params.q) then
        where[#where + 1] = "email ILIKE ?"
        vals[#vals + 1] = "%" .. tostring(params.q):gsub("[%%_\\]", "\\%0") .. "%"
    end
    return U.arr(db.query([[
        SELECT uuid, email, tier, billing_interval, status, net_minor, vat_minor, joined_at, current_period_end,
               cancel_at_period_end, fees_paid_net_minor, fees_credited_net_minor, terms_version
          FROM shop_memberships WHERE ]] .. table.concat(where, " AND ") .. [[
         ORDER BY joined_at DESC NULLS LAST LIMIT 1000
    ]], unpack(vals)))
end

return Q
