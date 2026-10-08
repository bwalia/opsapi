--[[
    Billing & Entitlements — purchases, fulfilment, upgrades, plan history
    ======================================================================
    docs/BILLING_ENTITLEMENTS.md §5 / §6 / §12 / §13.

    fulfil() is the one path every sale takes (manual, store, external, and
    Stripe checkout in phase 2):
      recurring  -> a subscription (manual / store; Stripe's come from webhooks)
      one_time   -> a purchase: perpetual access, updates for updates_days (or forever)
      fixed_term -> a purchase of term_days of access or of updates, stacking:
                    buying again extends from max(now, current end)
    For apps that use licences (desktop, self-hosted) the customer's licence for
    the plan is created or extended, so the same key keeps working.
    Every plan change is recorded in billing_plan_changes.
]]

local db = require("lapis.db")
local cjson = require("cjson")
local Common = require("queries.FieldServiceCommon")
local Apps = require("queries.BillingAppQueries")
local Subs = require("queries.BillingSubscriptionQueries")
local Licenses = require("queries.BillingLicenseQueries")
local Offers = require("queries.BillingOfferQueries")
local CustomerQueries = require("queries.CustomerQueries")
local EntitlementService = require("helper.entitlement-service")
local Settings = require("lib.billing-settings")

local Purchases = {}

local SOURCES = { stripe = true, manual = true, app_store = true, play_store = true, external = true }
Purchases.SOURCES = SOURCES

local function at(epoch) return epoch and db.raw(("to_timestamp(%d)"):format(epoch)) or db.NULL end

--- The access / updates window a new purchase of `plan` gets (unix seconds; nil = no end).
function Purchases.windows(plan, app_id, customer_id)
    local now = ngx.time()
    if plan.purchase_type == "one_time" then
        local d = tonumber(plan.updates_days)
        return nil, d and now + d * 86400 or nil
    end
    -- fixed_term: stacks on the latest end of this plan's active purchases. Locked
    -- first, so two purchases at once can't both stack on the same end.
    db.query("SELECT pg_advisory_xact_lock(hashtext(?))", ("opsapi.billing.stack:%s:%s:%s"):format(app_id, customer_id, plan.id))
    local col = plan.term_covers == "updates" and "updates_until" or "access_until"
    local cur = db.query(("SELECT extract(epoch FROM max(%s))::bigint AS t FROM billing_purchases "
        .. "WHERE app_id = ? AND customer_id = ? AND plan_id = ? AND status = 'active'"):format(col),
        app_id, customer_id, plan.id)[1].t
    local finish = math.max(now, tonumber(cur) or 0) + tonumber(plan.term_days) * 86400
    if col == "access_until" then return finish, nil end
    return nil, finish
end

--- The customer's current paid plan in an app (subscription, else newest purchase,
-- else newest licence with a plan). @return plan row | nil
function Purchases.currentPlan(app, customer_id)
    return db.query([[
        SELECT p.* FROM (
            SELECT plan_id, 1 AS rank, created_at FROM billing_subscriptions s
             WHERE app_id = ? AND customer_id = ? AND ]] .. EntitlementService.liveSubscriptionSql("s") .. [[
            UNION ALL
            SELECT plan_id, 2, created_at FROM billing_purchases
             WHERE app_id = ? AND customer_id = ? AND status = 'active' AND (access_until IS NULL OR access_until > NOW())
            UNION ALL
            SELECT plan_id, 3, created_at FROM billing_licenses
             WHERE app_id = ? AND customer_id = ? AND status = 'active' AND plan_id IS NOT NULL
        ) x JOIN billing_plans p ON p.id = x.plan_id
        ORDER BY x.rank, x.created_at DESC LIMIT 1]], app.id, customer_id, Settings.resolve(app).past_due_grace_days,
        app.id, customer_id, app.id, customer_id)[1]
end

--- Record a plan change. f: { app, customer_id, from_plan?, to_plan?, kind, source, amount?, currency?,
-- coupon_id?, purchase_id?, subscription_id?, license_id?, actor?, note? }
function Purchases.recordChange(f)
    db.insert("billing_plan_changes", {
        uuid = Common.uuid(), namespace_id = f.app.namespace_id, app_id = f.app.id, customer_id = f.customer_id,
        from_plan_id = f.from_plan and f.from_plan.id or db.NULL, to_plan_id = f.to_plan and f.to_plan.id or db.NULL,
        kind = f.kind, source = f.source, amount = f.amount or 0, currency = f.currency or db.NULL,
        coupon_id = f.coupon_id or db.NULL, purchase_id = f.purchase_id or db.NULL,
        subscription_id = f.subscription_id or db.NULL, license_id = f.license_id or db.NULL,
        actor = f.actor or db.NULL, note = f.note or db.NULL,
    })
end

-- Create or extend the customer's licence for a plan, backed by a purchase or a subscription.
-- @return licence row, raw key (only when newly issued)
local function licence_for(app, customer, plan, access_until, updates_until, purchase_id, source, from_plan,
                           subscription_id)
    local plan_ids = { plan.id }
    if from_plan then plan_ids[2] = from_plan.id end
    local lic = db.query([[SELECT * FROM billing_licenses WHERE app_id = ? AND customer_id = ? AND plan_id IN ?
        AND status <> 'revoked' ORDER BY created_at DESC LIMIT 1]], app.id, customer.id, db.list(plan_ids))[1]
    if lic then
        -- Extending never shortens: each window keeps the later end (no end = forever).
        local function later(col, t)
            if not t then return db.NULL end
            return db.raw(("CASE WHEN %s IS NULL THEN NULL ELSE GREATEST(%s, to_timestamp(%d)) END"):format(col, col, t))
        end
        db.update("billing_licenses", { plan_id = plan.id, access_until = later("access_until", access_until),
            updates_until = later("updates_until", updates_until),
            purchase_id = purchase_id or db.NULL, subscription_id = subscription_id or db.NULL,
            status = lic.status == "expired" and "active" or lic.status, updated_at = db.raw("NOW()") }, { id = lic.id })
        return lic, nil
    end
    return Licenses.issue(app, customer, { plan_id = plan.id, access_until = at(access_until),
        updates_until = at(updates_until), purchase_id = purchase_id or db.NULL,
        subscription_id = subscription_id or db.NULL, source = source })
end

--- Fulfil a sale. opts: { source, external_transaction_id?, original_transaction_id?, amount?, currency?,
-- coupon? (from checkCoupon), discount?, checkout_session? (a paid Stripe checkout: confirms its coupon
-- reservation), actor?, note?, expires_at? (recurring), metadata?, issue_licence? (default: licensed apps),
-- kind? ('new'|'upgrade'|...), from_plan?, stripe? { subscription_id, customer_id, payment_intent } }
-- @return { purchase?, subscription?, license?, key? } | nil, err   (run inside a transaction)
function Purchases.fulfil(app, customer, plan, opts)
    local source = opts.source
    local out = {}
    local amount = tonumber(opts.amount) or tonumber(plan.amount) or 0
    local currency = opts.currency or plan.currency
    local purchase_id, subscription_id
    local stripe = opts.stripe or {}
    local issue = opts.issue_licence
    if issue == nil then issue = Settings.isLicensed(app) end

    if plan.purchase_type == "recurring" then
        local f = {
            namespace_id = app.namespace_id, app_id = app.id, customer_id = customer.id, plan_id = plan.id,
            provider = source, source = source, status = "active",
            current_period_start = db.raw("NOW() AT TIME ZONE 'UTC'"),
            current_period_end = opts.expires_at and db.raw(("to_timestamp(%d) AT TIME ZONE 'UTC'"):format(opts.expires_at))
                or db.NULL,
            external_transaction_id = opts.external_transaction_id or db.NULL,
            original_transaction_id = opts.original_transaction_id or db.NULL,
            stripe_subscription_id = stripe.subscription_id or db.NULL, stripe_customer_id = stripe.customer_id or db.NULL,
            updated_at = db.raw("NOW()"),
        }
        local existing = opts.original_transaction_id and db.query([[SELECT id FROM billing_subscriptions
            WHERE namespace_id = ? AND app_id = ? AND source = ? AND original_transaction_id = ?]],
            app.namespace_id, app.id, source, opts.original_transaction_id)[1]
        if existing then
            db.update("billing_subscriptions", f, { id = existing.id })
            subscription_id = existing.id
        else
            f.uuid = Common.uuid()
            subscription_id = db.insert("billing_subscriptions", f, { returning = { "id" } })[1].id
        end
        out.subscription = db.query("SELECT uuid, status, source FROM billing_subscriptions WHERE id = ?", subscription_id)[1]
        -- Licensed apps: the licence runs to the end of the paid period (extended on each renewal).
        if issue then
            local lic, key = licence_for(app, customer, plan, opts.expires_at, nil, nil, source, opts.from_plan,
                subscription_id)
            out.license = Licenses.get(app.namespace_id, lic.uuid)
            out.key = key
        end
    else
        local access_until, updates_until = Purchases.windows(plan, app.id, customer.id)
        local row = db.insert("billing_purchases", {
            uuid = Common.uuid(), namespace_id = app.namespace_id, app_id = app.id, customer_id = customer.id,
            plan_id = plan.id, purchase_type = plan.purchase_type, source = source,
            external_transaction_id = opts.external_transaction_id or db.NULL,
            original_transaction_id = opts.original_transaction_id or db.NULL,
            access_until = at(access_until), updates_until = at(updates_until),
            amount = amount, currency = currency, coupon_id = opts.coupon and opts.coupon.id or db.NULL,
            metadata = db.raw(db.escape_literal(require("lib.billing-signing").encode(opts.metadata or {})) .. "::jsonb"),
            stripe_payment_intent_id = stripe.payment_intent or db.NULL,
            created_by = opts.actor or db.NULL,
        }, { returning = "*" })[1]
        purchase_id = row.id
        out.purchase = Purchases.present(row)
        if issue then
            local lic, key = licence_for(app, customer, plan, access_until, updates_until, purchase_id, source,
                opts.from_plan)
            db.query("UPDATE billing_purchases SET license_id = ? WHERE id = ?", lic.id, purchase_id)
            out.license = Licenses.get(app.namespace_id, lic.uuid)
            out.key = key
        end
    end

    if opts.coupon then
        local refs = { purchase_id = purchase_id, subscription_id = subscription_id }
        local confirmed = opts.checkout_session
            and Offers.confirm(opts.checkout_session, customer.id, opts.discount or 0, currency, refs)
        if not confirmed then
            local ok, cerr = Offers.redeem(opts.coupon, customer.id, opts.discount or 0, currency, refs,
                opts.checkout_session ~= nil)
            if not ok then return nil, cerr end
        end
    end
    Purchases.recordChange({ app = app, customer_id = customer.id, from_plan = opts.from_plan, to_plan = plan,
        kind = opts.kind or "new", source = source, amount = amount, currency = currency,
        coupon_id = opts.coupon and opts.coupon.id, purchase_id = purchase_id, subscription_id = subscription_id,
        license_id = out.license and db.query("SELECT id FROM billing_licenses WHERE uuid = ?", out.license.uuid)[1].id,
        actor = opts.actor, note = opts.note })
    EntitlementService.bust(app, customer.id)
    return out
end

function Purchases.present(row)
    if not row then return nil end
    return { uuid = row.uuid, purchase_type = row.purchase_type, source = row.source, status = row.status,
        access_until = row.access_until, updates_until = row.updates_until, amount = tonumber(row.amount),
        currency = row.currency, external_transaction_id = row.external_transaction_id ~= db.NULL
            and row.external_transaction_id or nil, created_at = row.created_at }
end

-- Customer by uuid (management) or external id (runtime, created on first sight).
local function resolve_customer(app, b)
    if Common.nilify(b.customer) then
        local c = Subs.customer(app.namespace_id, b.customer)
        if c then return c end
    end
    local ext = b.customer_external_id or b.external_id
    if Common.nilify(ext) then
        -- email_collection: none drops a given email; a new customer without one gets
        -- a placeholder unique to them (never emailed) unless the app requires emails.
        local mode = Settings.resolve(app).email_collection
        local email = mode ~= "none" and b.email or nil
        if not email and mode ~= "required" and not db.query(
            "SELECT 1 FROM customers WHERE namespace_id = ? AND external_id = ?", app.namespace_id, tostring(ext))[1] then
            email = ("%s+%s@customers.invalid"):format(ngx.md5(tostring(ext)):sub(1, 16), app.uuid:sub(1, 8))
        end
        local c, err = CustomerQueries.upsertExternal(app.namespace_id, ext, { email = email })
        if not c then return nil, err end
        return c
    end
    return nil, "Customer not found"
end

--- A sale recorded by an admin (cash, invoice, reseller, comp...). b: { app, customer | customer_external_id,
-- plan, amount?, coupon?, note? }. @return result (with the licence key once) | nil, err
function Purchases.sell(namespace_id, actor, b)
    local app = Apps.find(namespace_id, b.app)
    if not app then return nil, "App not found" end
    local customer, cerr = resolve_customer(app, b)
    if not customer then return nil, cerr end
    local plan = Subs.appPlan(app.id, tostring(b.plan or ""))
    if not plan then return nil, "Plan not found in this app" end
    local amount = b.amount ~= nil and tonumber(b.amount) or tonumber(plan.amount)
    if not amount or amount < 0 or amount ~= math.floor(amount) then return nil, "amount must be minor units (>= 0)" end
    local coupon, discount
    if Common.nilify(b.coupon) then
        local res, code, msg = Offers.checkCoupon(namespace_id, app, b.coupon, plan, amount, plan.currency, customer.id)
        if not res then return nil, msg, code end
        coupon, discount, amount = res.coupon, res.discount, res.total
    end
    local expires_at
    if plan.purchase_type == "recurring" then
        if not Common.nilify(b.expires_at) then return nil, "a recurring plan sold by hand needs expires_at (period end)" end
        local ok, rows = pcall(db.query, "SELECT extract(epoch FROM ?::timestamptz)::bigint AS t", tostring(b.expires_at))
        if not ok then return nil, "expires_at must be an ISO-8601 date-time" end
        expires_at = rows[1].t
    end
    return Common.transaction(function()
        return Purchases.fulfil(app, customer, plan, { source = "manual", amount = amount, coupon = coupon,
            discount = discount, actor = actor, note = b.note, expires_at = tonumber(expires_at) })
    end)
end

--- Upgrade a customer to `to_plan` along an admin-defined path. quote = true
-- only prices it. b: { app, customer | customer_external_id, to_plan, coupon?, note? }
function Purchases.upgrade(namespace_id, actor, b, quote)
    local app = Apps.find(namespace_id, b.app)
    if not app then return nil, "App not found" end
    local customer, cerr = resolve_customer(app, b)
    if not customer then return nil, cerr end
    local to_plan = Subs.appPlan(app.id, tostring(b.to_plan or ""))
    if not to_plan then return nil, "Plan not found in this app" end
    local from_plan = Purchases.currentPlan(app, customer.id)
    if not from_plan then return nil, "The customer has no plan to upgrade from: sell the plan instead" end
    if tonumber(from_plan.id) == tonumber(to_plan.id) then return nil, "The customer is already on this plan" end
    local price, perr = Offers.upgradePrice(app, from_plan, to_plan)
    if not price then return nil, perr end
    local amount, coupon, discount = price.amount, nil, 0
    if Common.nilify(b.coupon) then
        local res, code, msg = Offers.checkCoupon(namespace_id, app, b.coupon, to_plan, amount, price.currency, customer.id)
        if not res then return nil, msg, code end
        coupon, discount, amount = res.coupon, res.discount, res.total
    end
    local summary = { from_plan = { uuid = from_plan.uuid, key = from_plan.plan_key, name = from_plan.name },
        to_plan = { uuid = to_plan.uuid, key = to_plan.plan_key, name = to_plan.name },
        pricing = price.path.pricing, amount = amount, discount = discount, currency = price.currency }
    if quote then return summary end
    local kind = tonumber(to_plan.amount) < tonumber(from_plan.amount) and "downgrade" or "upgrade"
    local sub = to_plan.purchase_type == "recurring" and db.query([[SELECT * FROM billing_subscriptions
        WHERE app_id = ? AND customer_id = ? AND status IN ('active', 'trialing', 'past_due')
        ORDER BY created_at DESC LIMIT 1]], app.id, customer.id)[1]
    if to_plan.purchase_type == "recurring" and not sub then
        return nil, "The customer has no subscription to switch: sell the plan instead"
    end
    if sub and sub.source == "stripe" then
        -- Stripe invoices the prorated difference now and applies the switch once
        -- it is paid; the webhook then moves the plan and records the change.
        if coupon then return nil, "Coupons can't be applied when switching a Stripe subscription", "coupon_not_allowed" end
        local ok, serr = require("lib.billing-stripe").switchPlan(sub, to_plan)
        if not ok then return nil, serr.message, serr.code end
        summary.pending = true
        return summary
    end
    return Common.transaction(function()
        local res, ferr
        if sub then
            db.update("billing_subscriptions", { plan_id = to_plan.id, updated_at = db.raw("NOW()") }, { id = sub.id })
            db.query([[UPDATE billing_licenses SET plan_id = ?, updated_at = NOW() WHERE app_id = ? AND customer_id = ?
                AND plan_id = ? AND status <> 'revoked']], to_plan.id, app.id, customer.id, from_plan.id)
            Purchases.recordChange({ app = app, customer_id = customer.id, from_plan = from_plan, to_plan = to_plan,
                kind = kind, source = "manual", amount = amount, currency = price.currency,
                coupon_id = coupon and coupon.id, subscription_id = sub.id, actor = actor, note = b.note })
            if coupon then Offers.redeem(coupon, customer.id, discount, price.currency, { subscription_id = sub.id }) end
            EntitlementService.bust(app, customer.id)
            res = {}
        else
            res, ferr = Purchases.fulfil(app, customer, to_plan, { source = "manual", amount = amount,
                currency = price.currency, coupon = coupon, discount = discount, actor = actor, note = b.note,
                kind = kind, from_plan = from_plan })
            if not res then return nil, ferr end
        end
        for k, v in pairs(summary) do res[k] = v end
        return res
    end)
end

--- A verified purchase recorded by the client's own server (store or external).
-- b: { customer_external_id, email?, plan_key | store_product_id, source, external_transaction_id,
--      original_transaction_id?, expires_at? (unix, recurring), amount?, currency?, status? ('active'|'refunded'|'canceled') }
function Purchases.recordExternal(app, b)
    local source = b.source
    if source == "stripe" or not SOURCES[source] then
        return nil, "source must be app_store, play_store, external or manual"
    end
    if type(b.external_transaction_id) ~= "string" or b.external_transaction_id == "" or #b.external_transaction_id > 200 then
        return nil, "external_transaction_id is required"
    end
    local customer, cerr = resolve_customer(app, { customer_external_id = b.customer_external_id, email = b.email })
    if not customer then return nil, cerr end
    local plan
    if Common.nilify(b.plan_key) then
        plan = Subs.appPlan(app.id, b.plan_key)
    elseif Common.nilify(b.store_product_id) then
        plan = db.query([[SELECT * FROM billing_plans WHERE app_id = ? AND deleted_at IS NULL
            AND store_products ->> ? = ? LIMIT 1]], app.id, source, b.store_product_id)[1]
    end
    if not plan then return nil, "Plan not found (send plan_key, or a store_product_id set on a plan)" end
    local status = b.status or "active"
    return Common.transaction(function()
        if plan.purchase_type ~= "recurring" then
            local existing = db.query([[SELECT * FROM billing_purchases WHERE app_id = ? AND source = ?
                AND external_transaction_id = ?]], app.id, source, b.external_transaction_id)[1]
            if existing then
                if status == "refunded" and existing.status == "active" then
                    Purchases.refund(app, existing)
                end
                return { purchase = Purchases.present(db.query("SELECT * FROM billing_purchases WHERE id = ?", existing.id)[1]),
                    duplicate = true }
            end
            if status ~= "active" then return nil, "nothing to record: an unknown transaction that isn't active" end
            return Purchases.fulfil(app, customer, plan, { source = source, amount = b.amount, currency = b.currency,
                external_transaction_id = b.external_transaction_id, original_transaction_id = b.original_transaction_id })
        end
        local res, ferr = Purchases.fulfil(app, customer, plan, { source = source, amount = b.amount, currency = b.currency,
            external_transaction_id = b.external_transaction_id,
            original_transaction_id = b.original_transaction_id or b.external_transaction_id,
            expires_at = tonumber(b.expires_at), kind = "renewal" })
        if res and status ~= "active" then
            db.query("UPDATE billing_subscriptions SET status = 'canceled', canceled_at = NOW(), updated_at = NOW() WHERE uuid = ?",
                res.subscription.uuid)
        end
        return res, ferr
    end)
end

-- Undo what an ended purchase granted on its licence: the licence falls back
-- to the newest purchase still active on it, or is revoked when none is left
-- (unless a live subscription backs it). Purchases record their licence
-- (license_id), so an upgrade or a renewal never moves what a refund undoes.
local function release_licence(app, purchase)
    local lic = db.query([[SELECT * FROM billing_licenses WHERE status <> 'revoked'
        AND id = COALESCE(?, (SELECT id FROM billing_licenses WHERE purchase_id = ? LIMIT 1))]],
        purchase.license_id ~= db.NULL and purchase.license_id or db.NULL, purchase.id)[1]
    if not lic then return end
    local left = db.query([[SELECT * FROM billing_purchases WHERE license_id = ? AND status = 'active' AND id <> ?
        ORDER BY created_at DESC LIMIT 1]], lic.id, purchase.id)[1]
    if left then
        db.update("billing_licenses", { plan_id = left.plan_id, access_until = left.access_until or db.NULL,
            updates_until = left.updates_until or db.NULL, purchase_id = left.id, updated_at = db.raw("NOW()") },
            { id = lic.id })
        return
    end
    if lic.subscription_id ~= db.NULL and lic.subscription_id then
        local live = db.query("SELECT 1 FROM billing_subscriptions s WHERE s.id = ? AND "
            .. EntitlementService.liveSubscriptionSql("s"), lic.subscription_id, Settings.resolve(app).past_due_grace_days)[1]
        if live then return end
    end
    Licenses.revoke(app.namespace_id, lic.uuid)
end

--- A full refund: the app's refund_policy decides (revoke: purchase refunded and
-- what it granted undone; keep: recorded only).
function Purchases.refund(app, purchase, refunded_amount)
    local policy = Settings.resolve(app).refund_policy
    db.query([[UPDATE billing_purchases SET status = CASE WHEN ? = 'revoke' THEN 'refunded' ELSE status END,
        refunded_amount = ?, refunded_at = NOW(), updated_at = NOW() WHERE id = ?]],
        policy, refunded_amount or purchase.amount, purchase.id)
    if policy == "revoke" then release_licence(app, purchase) end
    EntitlementService.bust(app, purchase.customer_id)
end

--- Revoke a purchase by hand (and the licences it fulfilled).
function Purchases.revoke(namespace_id, uuid, actor)
    return Common.transaction(function()
        local p = db.query("SELECT * FROM billing_purchases WHERE namespace_id = ? AND uuid = ? AND status = 'active'",
            namespace_id, uuid)[1]
        if not p then return nil, "Purchase not found" end
        db.query("UPDATE billing_purchases SET status = 'revoked', updated_at = NOW() WHERE id = ?", p.id)
        local app = db.query("SELECT * FROM billing_apps WHERE id = ?", p.app_id)[1]
        release_licence(app, p)
        Purchases.recordChange({ app = app, customer_id = p.customer_id,
            from_plan = { id = p.plan_id }, kind = "cancel", source = "manual", actor = actor })
        EntitlementService.bust(app, p.customer_id)
        return true
    end)
end

local LIST = [[
    SELECT pu.uuid, pu.purchase_type, pu.source, pu.status, pu.access_until, pu.updates_until, pu.amount, pu.currency,
           pu.external_transaction_id, pu.refunded_amount, pu.refunded_at, pu.created_by, pu.created_at,
           a.uuid AS app_uuid, a.name AS app_name, p.uuid AS plan_uuid, p.plan_key, p.name AS plan_name,
           c.uuid AS customer_uuid, c.email AS customer_email, c.external_id AS customer_external_id,
           co.code AS coupon_code
    FROM billing_purchases pu JOIN billing_apps a ON a.id = pu.app_id JOIN billing_plans p ON p.id = pu.plan_id
    JOIN customers c ON c.id = pu.customer_id LEFT JOIN billing_coupons co ON co.id = pu.coupon_id
]]

local function filtered(sql, alias, namespace_id, params, extra)
    local where, vals = { alias .. ".namespace_id = ?" }, { namespace_id }
    if Common.nilify(params.app) then
        where[#where + 1] = "(a.uuid = ? OR a.slug = ?)"
        vals[#vals + 1], vals[#vals + 2] = params.app, params.app
    end
    if Common.nilify(params.customer) then
        where[#where + 1] = "c.uuid = ?"
        vals[#vals + 1] = params.customer
    end
    for _, e in ipairs(extra or {}) do
        if Common.nilify(params[e[1]]) then
            where[#where + 1] = e[2]
            vals[#vals + 1] = params[e[1]]
        end
    end
    local page, per_page, offset = Common.paging(params)
    local q = sql .. " WHERE " .. table.concat(where, " AND ")
    local total = db.query("SELECT count(*) AS n FROM (" .. q .. ") x", unpack(vals))[1].n
    vals[#vals + 1], vals[#vals + 2] = per_page, offset
    return q, vals, total, page, per_page
end

function Purchases.list(namespace_id, params)
    local q, vals, total, page, per_page = filtered(LIST, "pu", namespace_id, params,
        { { "status", "pu.status = ?" }, { "source", "pu.source = ?" } })
    local rows = db.query(q .. " ORDER BY pu.created_at DESC LIMIT ? OFFSET ?", unpack(vals))
    for _, r in ipairs(rows) do r.amount = tonumber(r.amount) end
    return Common.arr(rows), Common.meta(total, page, per_page)
end

function Purchases.planChanges(namespace_id, params)
    local sql = [[
        SELECT h.uuid, h.kind, h.source, h.amount, h.currency, h.actor, h.note, h.created_at,
               a.uuid AS app_uuid, a.name AS app_name, c.uuid AS customer_uuid, c.email AS customer_email,
               f.uuid AS from_plan_uuid, f.name AS from_plan_name, t.uuid AS to_plan_uuid, t.name AS to_plan_name,
               co.code AS coupon_code
        FROM billing_plan_changes h JOIN billing_apps a ON a.id = h.app_id JOIN customers c ON c.id = h.customer_id
        LEFT JOIN billing_plans f ON f.id = h.from_plan_id LEFT JOIN billing_plans t ON t.id = h.to_plan_id
        LEFT JOIN billing_coupons co ON co.id = h.coupon_id
    ]]
    local q, vals, total, page, per_page = filtered(sql, "h", namespace_id, params, { { "kind", "h.kind = ?" } })
    local rows = db.query(q .. " ORDER BY h.created_at DESC LIMIT ? OFFSET ?", unpack(vals))
    for _, r in ipairs(rows) do r.amount = tonumber(r.amount) end
    return Common.arr(rows), Common.meta(total, page, per_page)
end

--- A customer's purchases, subscriptions and plan history in one app (the
-- "my licences" page; no other customers' data).
function Purchases.forCustomer(app, customer_id)
    local purchases = db.query(LIST .. " WHERE pu.app_id = ? AND pu.customer_id = ? ORDER BY pu.created_at DESC",
        app.id, customer_id)
    for _, r in ipairs(purchases) do
        r.amount, r.customer_email, r.customer_external_id, r.created_by = tonumber(r.amount), nil, nil, nil
    end
    local subs = db.query([[SELECT s.uuid, s.status, s.source, s.current_period_end, s.cancel_at_period_end,
            p.uuid AS plan_uuid, p.plan_key, p.name AS plan_name
        FROM billing_subscriptions s LEFT JOIN billing_plans p ON p.id = s.plan_id
        WHERE s.app_id = ? AND s.customer_id = ? ORDER BY s.created_at DESC]], app.id, customer_id)
    return Common.arr(purchases), Common.arr(subs)
end

return Purchases
