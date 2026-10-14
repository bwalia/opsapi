--[[
    ATS — payment activation (docs/plans/PROMPT_ATS_INTERVIEWS.md §6).

    A namespace's payment turns the module on. A lapsed one keeps its data
    readable, reviewable and exportable, but can't invite anyone new or start
    an interview that hasn't begun.

      ATS_STRIPE_PRICE_ID         the recurring price checkout sells
      ATS_STRIPE_WEBHOOK_SECRET   signing secret of /api/v2/public/ats/billing/webhook
                                  (falls back to STRIPE_WEBHOOK_SECRET)
      ATS_PAST_DUE_GRACE_DAYS     days a failed renewal keeps access (default 7)
      ATS_PUBLIC_URL / FRONTEND_URL   dashboard base for checkout's return URLs
]]

local db = require("lapis.db")
local J = require("lib.ats.json")

local A = {}

local function env(name)
    local v = os.getenv(name)
    if v == nil or v == "" then return nil end
    return v
end

function A.public_url()
    return ((env("ATS_PUBLIC_URL") or env("FRONTEND_URL") or "http://localhost:8039"):gsub("/+$", ""))
end

local function grace_days()
    return tonumber(env("ATS_PAST_DUE_GRACE_DAYS")) or 7
end

function A.row(namespace_id)
    return db.select("* FROM ats_module_activations WHERE namespace_id = ?", namespace_id)[1]
end

--- Is the module paid for right now?
function A.is_active(namespace_id)
    local r = db.query([[
        SELECT 1 FROM ats_module_activations WHERE namespace_id = ? AND status = 'active'
          AND (expires_at IS NULL OR expires_at + interval '1 day' > NOW())
          AND (payment_failed_at IS NULL OR payment_failed_at + (? || ' days')::interval > NOW())
    ]], namespace_id, tostring(grace_days()))
    return r[1] ~= nil
end

function A.status(namespace_id)
    local r = A.row(namespace_id)
    local active = A.is_active(namespace_id)
    return {
        active = active,
        status = r and r.status or "inactive",
        source = r and r.source or nil,
        activated_at = r and J.val(r.activated_at) or nil,
        expires_at = r and J.val(r.expires_at) or nil,
        payment_failed_at = r and J.val(r.payment_failed_at) or nil,
        checkout_available = env("ATS_STRIPE_PRICE_ID") ~= nil,
    }
end

A.LAPSED_MESSAGE = "Snazzy Interview isn't active for this workspace. Existing interviews stay readable and "
    .. "exportable; activate it in Hiring › Settings to invite candidates."

--- nil when active, else a 402 response.
function A.require_active(namespace_id)
    if A.is_active(namespace_id) then return nil end
    return { status = 402, json = { success = false, error = A.LAPSED_MESSAGE, code = "ats_inactive" } }
end

local function upsert(namespace_id, fields)
    local existing = A.row(namespace_id)
    fields.updated_at = db.raw("NOW()")
    if existing then
        db.update("ats_module_activations", fields, { id = existing.id })
    else
        fields.namespace_id = namespace_id
        db.insert("ats_module_activations", fields)
    end
end

--- Platform admin: activate (optionally until a date) or lapse by hand.
function A.set_manual(namespace_id, status, expires_at, actor)
    if status ~= "active" and status ~= "lapsed" then return nil, "status must be active or lapsed" end
    upsert(namespace_id, {
        status = status, source = "manual", expires_at = expires_at or db.NULL, payment_failed_at = db.NULL,
        activated_at = status == "active" and db.raw("NOW()") or nil,
        lapsed_at = status == "lapsed" and db.raw("NOW()") or db.NULL, updated_by = actor,
    })
    return A.status(namespace_id)
end

--- A Stripe Checkout session for the namespace. @return {checkout_url, session_id} | nil, err
function A.checkout(namespace, user)
    local price = env("ATS_STRIPE_PRICE_ID")
    if not price then return nil, "Checkout isn't set up on this server (ATS_STRIPE_PRICE_ID)." end
    local stripe, err = require("lib.payment-provider").get_stripe()
    if not stripe then return nil, err end
    local base = A.public_url() .. "/dashboard/ats/settings"
    local meta = { namespace_uuid = namespace.uuid, namespace_id = tostring(namespace.id), module = "ats" }
    local session, serr = stripe:create_checkout_session({
        mode = "subscription",
        line_items = { { price = price, quantity = 1 } },
        success_url = base .. "?activation=success",
        cancel_url = base .. "?activation=cancelled",
        customer_email = user and user.email or nil,
        client_reference_id = namespace.uuid,
        metadata = meta,
        subscription_data = { metadata = meta },
        allow_promotion_codes = true,
    })
    if not session then return nil, serr or "Stripe didn't create a checkout session." end
    return { checkout_url = session.url, session_id = session.id }
end

local function namespace_of(meta)
    meta = type(meta) == "table" and meta or {}
    if J.val(meta.module) ~= "ats" then return nil end
    local uuid = J.val(meta.namespace_uuid)
    if not uuid then return nil end
    local ns = db.select("id FROM namespaces WHERE uuid = ?", uuid)[1]
    return ns and ns.id or nil
end

local function iso_from_unix(t)
    t = tonumber(t)
    return t and db.raw(("to_timestamp(%d)"):format(math.floor(t))) or nil
end

--- Applies a verified Stripe event. @return true (handled or ignored)
function A.handle_event(event)
    local obj = event.data and event.data.object or {}
    local t = event.type
    if t == "checkout.session.completed" then
        local ns = namespace_of(obj.metadata)
        if not ns then return true end
        upsert(ns, { status = "active", source = "stripe", stripe_customer_id = J.val(obj.customer),
            stripe_subscription_id = J.val(obj.subscription), activated_at = db.raw("NOW()"),
            payment_failed_at = db.NULL, lapsed_at = db.NULL })
    elseif t == "invoice.paid" then
        local sub = J.val(obj.subscription)
        local row = sub and db.select("* FROM ats_module_activations WHERE stripe_subscription_id = ?", sub)[1]
        if not row then
            local meta = obj.subscription_details and obj.subscription_details.metadata
            local ns = namespace_of(meta)
            if not ns then return true end
            upsert(ns, { status = "active", source = "stripe", stripe_subscription_id = sub,
                stripe_customer_id = J.val(obj.customer), activated_at = db.raw("NOW()") })
            row = A.row(ns)
        end
        local period_end = obj.lines and obj.lines.data and obj.lines.data[1] and obj.lines.data[1].period
            and obj.lines.data[1].period["end"]
        db.update("ats_module_activations", { status = "active", payment_failed_at = db.NULL, lapsed_at = db.NULL,
            expires_at = iso_from_unix(period_end) or db.NULL, updated_at = db.raw("NOW()") }, { id = row.id })
    elseif t == "invoice.payment_failed" then
        local sub = J.val(obj.subscription)
        if sub then
            db.query([[UPDATE ats_module_activations SET payment_failed_at = COALESCE(payment_failed_at, NOW()),
                updated_at = NOW() WHERE stripe_subscription_id = ?]], sub)
        end
    elseif t == "customer.subscription.deleted" then
        db.query([[UPDATE ats_module_activations SET status = 'lapsed', lapsed_at = NOW(), updated_at = NOW()
            WHERE stripe_subscription_id = ?]], J.val(obj.id) or "")
    elseif t == "customer.subscription.updated" then
        local period_end = iso_from_unix(obj.current_period_end)
        if period_end and J.val(obj.id) then
            db.update("ats_module_activations", { expires_at = period_end, updated_at = db.raw("NOW()") },
                { stripe_subscription_id = obj.id })
        end
    end
    return true
end

return A
