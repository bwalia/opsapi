-- luacheck: max line length 140
--[[
    Shop Stripe: webhook event application + reconciler
    ====================================================

    Webhook (routes/shop-stripe-webhook.lua) calls ShopStripeQueries.handleEvent
    which, in ONE transaction, inserts the event id into shop_stripe_events
    (ON CONFLICT DO NOTHING → duplicate = no-op), applies it, and commits. The
    route answers 200 only after the commit; a raised error rolls everything
    back (ledger row included) so Stripe's retry reprocesses it.

    Reconciler (timer on worker 0 every 300 s + POST /api/v2/shop/admin/reconcile):
      (a) pending_payment orders whose held reservations expired → ask Stripe;
          paid → mark paid; otherwise cancel + release
      (b) pending_payment orders Stripe reports as paid (missed webhook) → paid
      (c) release stale held reservations of non-pending orders
]]

local db = require("lapis.db")
local unpack = unpack or table.unpack -- luacheck: ignore 113 143
local Global = require("helper.global")
local U = require("lib.shop-util")
local Orders = require("queries.ShopOrderQueries")
local Stock = require("queries.ShopStockQueries")

local ShopStripeQueries = {}

local function nz(v) return U.nz(v) end

local function id_of(v)
    v = nz(v)
    if type(v) == "table" then return nz(v.id) end
    return v
end

--- Locate the order for a checkout session object (row locked FOR UPDATE).
local function order_for_session(session)
    local meta = type(session.metadata) == "table" and session.metadata or {}
    local uuid = nz(meta.order_uuid) or nz(session.client_reference_id)
    local row
    if uuid then
        row = db.query("SELECT " .. Orders.ORDER_COLS .. " FROM shop_orders o WHERE o.uuid = ? FOR UPDATE", uuid)[1]
    end
    if not row and nz(session.id) then
        row = db.query("SELECT " .. Orders.ORDER_COLS .. " FROM shop_orders o WHERE o.stripe_session_id = ? FOR UPDATE",
            session.id)[1]
    end
    return row
end

local function order_for_payment_intent(pi_id)
    if not pi_id then return nil end
    return db.query("SELECT " .. Orders.ORDER_COLS .. " FROM shop_orders o WHERE o.stripe_payment_intent_id = ? FOR UPDATE",
        pi_id)[1]
end

local handlers = {}

function handlers.session_completed(session)
    local order = order_for_session(session)
    if not order then return nil end
    local ps = nz(session.payment_status)
    if ps == "paid" or ps == "no_payment_required" then
        Orders.applyPaid(order, session)
    else
        -- async payment method (e.g. bank debit) still processing: remember the PI
        local pi = id_of(session.payment_intent)
        if pi then
            db.query("UPDATE shop_orders SET stripe_payment_intent_id = ?, updated_at = NOW() WHERE id = ?", pi, order.id)
        end
    end
    return order
end

function handlers.session_async_succeeded(session)
    local order = order_for_session(session)
    if order then Orders.applyPaid(order, session) end
    return order
end

function handlers.session_expired(session)
    local order = order_for_session(session)
    if order then Orders.applyUnpaid(order, "cancelled", "Checkout session expired") end
    return order
end

function handlers.session_async_failed(session)
    local order = order_for_session(session)
    if order then Orders.applyUnpaid(order, "payment_failed", "Asynchronous payment failed") end
    return order
end

function handlers.charge_refunded(charge)
    local order = order_for_payment_intent(id_of(charge.payment_intent))
    if not order then return nil end
    local refunded = tonumber(charge.amount_refunded) or 0
    local amount = tonumber(charge.amount) or 0
    if amount > 0 and refunded >= amount then
        db.query("UPDATE shop_orders SET status = 'refunded', updated_at = NOW() WHERE id = ?", order.id)
    else
        local note = string.format("[%s] Partial refund: %s of %s (charge %s)", os.date("!%Y-%m-%d %H:%M UTC"),
            U.money(refunded), U.money(amount), tostring(charge.id))
        db.query([[UPDATE shop_orders SET internal_notes = COALESCE(internal_notes || E'\n', '') || ?,
                   updated_at = NOW() WHERE id = ?]], note, order.id)
    end
    return order
end

local DISPATCH = {
    ["checkout.session.completed"] = handlers.session_completed,
    ["checkout.session.async_payment_succeeded"] = handlers.session_async_succeeded,
    ["checkout.session.expired"] = handlers.session_expired,
    ["checkout.session.async_payment_failed"] = handlers.session_async_failed,
    ["charge.refunded"] = handlers.charge_refunded,
}
ShopStripeQueries.HANDLED_EVENTS = DISPATCH

--- Apply a verified event exactly once.
-- Returns { duplicate = bool, ignored = bool, order_uuid } ; raises on failure
-- (after rolling back) so the route can answer 5xx.
function ShopStripeQueries.handleEvent(event)
    if type(event) ~= "table" or not nz(event.id) or not nz(event.type) then
        error("malformed event")
    end
    local result = { duplicate = false, ignored = false }
    local res, err = U.tx(function()
        local ins = db.query([[
            INSERT INTO shop_stripe_events (uuid, event_id, type, processed_at, created_at, updated_at)
            VALUES (?, ?, ?, NOW(), NOW(), NOW())
            ON CONFLICT (event_id) DO NOTHING
            RETURNING id
        ]], Global.generateUUID(), event.id, event.type)
        if #ins == 0 then
            result.duplicate = true
            return result
        end
        local handler = DISPATCH[event.type]
        if not handler then
            result.ignored = true
            return result
        end
        local object = event.data and event.data.object or {}
        local order = handler(object, event)
        if order then
            db.query("UPDATE shop_stripe_events SET order_id = ?, namespace_id = ? WHERE id = ?",
                order.id, order.namespace_id, ins[1].id)
            result.order_uuid = order.uuid
        end
        return result
    end)
    if not res then error(err and err.message or "event application failed") end
    return res
end

-- ---------------------------------------------------------------------------
-- reconciler
-- ---------------------------------------------------------------------------

--- Reconcile pending orders against Stripe. ns_id = nil → all namespaces.
-- Returns a summary table.
function ShopStripeQueries.reconcile(ns_id, opts)
    opts = opts or {}
    local summary = { checked = 0, marked_paid = 0, cancelled = 0, released = 0, errors = 0, skipped = 0 }
    local PaymentProvider = require("lib.payment-provider")
    local stripe
    if U.env("STRIPE_SECRET_KEY") then stripe = PaymentProvider.get_stripe() end

    local where = "o.status = 'pending_payment' AND o.created_at > NOW() - interval '7 days'"
    local vals = {}
    if ns_id then
        where = where .. " AND o.namespace_id = ?"
        vals[#vals + 1] = ns_id
    end
    vals[#vals + 1] = U.clamp(U.int(opts.limit, 100), 1, 500)
    local pending = db.query([[
        SELECT o.id, o.uuid, o.stripe_session_id, o.created_at,
               EXISTS (SELECT 1 FROM shop_stock_reservations r WHERE r.order_id = o.id AND r.status = 'held'
                         AND r.expires_at > NOW()) AS has_live_hold,
               (o.created_at < NOW() - interval '35 minutes') AS is_stale
          FROM shop_orders o
         WHERE ]] .. where .. " ORDER BY o.created_at LIMIT ?", unpack(vals))

    for _, p in ipairs(pending) do
        summary.checked = summary.checked + 1
        local expired = (not p.has_live_hold) and p.is_stale
        local session
        if stripe and nz(p.stripe_session_id) then
            local s, serr = stripe:retrieve_checkout_session(p.stripe_session_id)
            if s then
                session = s
            else
                summary.errors = summary.errors + 1
                ngx.log(ngx.WARN, "[shop-reconcile] retrieve session failed for ", p.uuid, ": ", tostring(serr))
            end
        end
        local ok, err = pcall(U.tx, function()
            local order = db.query("SELECT " .. Orders.ORDER_COLS .. " FROM shop_orders o WHERE o.id = ? FOR UPDATE",
                p.id)[1]
            if not order or order.status ~= "pending_payment" then return true end
            if session and (session.payment_status == "paid" or session.payment_status == "no_payment_required") then
                Orders.applyPaid(order, session)
                summary.marked_paid = summary.marked_paid + 1
            elseif expired then
                if session and session.status == "open" then
                    -- still payable on Stripe's side; leave it (it expires at 31 min anyway)
                    summary.skipped = summary.skipped + 1
                elseif session or not nz(order.stripe_session_id) or not stripe then
                    Orders.applyUnpaid(order, "cancelled", "Reconciler: checkout not completed before expiry")
                    summary.cancelled = summary.cancelled + 1
                else
                    summary.skipped = summary.skipped + 1 -- Stripe unreachable: try again next run
                end
            end
            return true
        end)
        if not ok then
            summary.errors = summary.errors + 1
            ngx.log(ngx.ERR, "[shop-reconcile] order ", p.uuid, ": ", tostring(err))
        end
    end

    local rel = Stock.releaseStale(ns_id)
    summary.released = rel and rel.affected_rows or 0
    return summary
end

--- Timer entry point: run the reconciler for every namespace (worker 0).
function ShopStripeQueries.timerTick(premature)
    if premature then return end
    local ok, res = pcall(ShopStripeQueries.reconcile, nil, {})
    if not ok then
        ngx.log(ngx.ERR, "[shop-reconcile] tick failed: ", tostring(res))
    elseif (res.marked_paid + res.cancelled + res.errors) > 0 then
        ngx.log(ngx.NOTICE, "[shop-reconcile] ", U.enc(res))
    end
    -- give the pooled connection back (timer contexts do not run after_dispatch)
    pcall(function()
        if db.query("SELECT now() <> statement_timestamp() AS open")[1].open then db.query("ROLLBACK") end
    end)
    pcall(require("lapis.nginx.context").run_after_dispatch)
end

return ShopStripeQueries
