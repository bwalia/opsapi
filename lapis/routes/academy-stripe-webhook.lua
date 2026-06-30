--[[
    Academy Stripe Webhook
    ======================
    POST /api/v2/public/academy/stripe/webhook  (no auth; signature-verified)

    The source of truth for granting access. Verifies the Stripe signature
    (reusing lib/stripe.construct_event), de-dupes by event id, then mirrors the
    event into our tables:
      - checkout.session.completed (course)       -> enroll the buyer
      - checkout.session.completed (subscription) -> create the subscription
      - invoice.paid                              -> extend the subscription
      - customer.subscription.updated/deleted     -> update status/period
      - account.updated                           -> creator onboarding status
]]

local Stripe = require("lib.stripe")
local Global = require("helper.global")
local db = require("lapis.db")
local EnrollmentQueries = require("queries.EnrollmentQueries")
local SubscriptionQueries = require("queries.SubscriptionQueries")

return function(app)
    -- Returns true if the event was already handled (idempotency). Inserts the
    -- marker; a unique-violation race also counts as "already processed".
    local function already_processed(event_id, etype)
        local rows = db.query("SELECT 1 FROM processed_stripe_events WHERE event_id = ? LIMIT 1", event_id)
        if rows and #rows > 0 then return true end
        local ok = pcall(function()
            db.query("INSERT INTO processed_stripe_events (event_id, type, created_at) VALUES (?, ?, NOW())",
                event_id, etype)
        end)
        return not ok
    end

    local function record_payment(p)
        pcall(function()
            db.query([[
                INSERT INTO academy_payments
                    (uuid, user_uuid, namespace_id, course_id, kind, stripe_ref, amount, platform_fee, currency, status, created_at, updated_at)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, NOW(), NOW())
            ]], Global.generateUUID(), p.user_uuid, p.namespace_id, p.course_id, p.kind, p.stripe_ref,
                p.amount or 0, p.platform_fee or 0, p.currency or "usd", p.status or "succeeded")
        end)
    end

    local function raw_body()
        ngx.req.read_body()
        local body = ngx.req.get_body_data()
        if body and body ~= "" then return body end
        local path = ngx.req.get_body_file()
        if path then
            local f = io.open(path, "rb")
            if f then local b = f:read("*a"); f:close(); return b end
        end
        return nil
    end

    app:post("/api/v2/public/academy/stripe/webhook", function(self)
        local payload = raw_body()
        local sig = ngx.var.http_stripe_signature
        local secret = Global.getEnvVar("STRIPE_ACADEMY_WEBHOOK_SECRET")
        if not secret or secret == "" then
            secret = Global.getEnvVar("STRIPE_WEBHOOK_SECRET")
        end

        local event, err = Stripe.construct_event(payload, sig, secret)
        if not event then
            ngx.log(ngx.WARN, "[academy webhook] signature verify failed: " .. tostring(err))
            return { status = 400, json = { error = "invalid signature" } }
        end

        if already_processed(event.id, event.type) then
            return { status = 200, json = { received = true, duplicate = true } }
        end

        local obj = (event.data and event.data.object) or {}
        local t = event.type

        if t == "checkout.session.completed" then
            local md = obj.metadata or {}
            local ns_id = tonumber(md.namespace_id)
            if md.kind == "course" and ns_id and tonumber(md.course_id) and md.user_uuid then
                pcall(EnrollmentQueries.enroll, ns_id, tonumber(md.course_id), md.user_uuid)
                record_payment({
                    user_uuid = md.user_uuid, namespace_id = ns_id, course_id = tonumber(md.course_id),
                    kind = "course", stripe_ref = obj.payment_intent, amount = obj.amount_total, currency = obj.currency,
                })
            elseif md.kind == "subscription" and ns_id and md.user_uuid and obj.subscription then
                local subobj = Stripe.new():retrieve_subscription(obj.subscription)
                SubscriptionQueries.upsert({
                    user_uuid = md.user_uuid, namespace_id = ns_id,
                    stripe_subscription_id = obj.subscription, stripe_customer_id = obj.customer,
                    status = subobj and subobj.status or "active",
                    current_period_end_unix = subobj and subobj.current_period_end or nil,
                })
                record_payment({
                    user_uuid = md.user_uuid, namespace_id = ns_id, kind = "subscription",
                    stripe_ref = obj.subscription, amount = obj.amount_total, currency = obj.currency,
                })
            end

        elseif t == "invoice.paid" then
            if obj.subscription then
                local subobj = Stripe.new():retrieve_subscription(obj.subscription)
                if subobj then
                    SubscriptionQueries.updateStatusByStripeId(obj.subscription, subobj.status, subobj.current_period_end)
                end
            end

        elseif t == "customer.subscription.updated" or t == "customer.subscription.deleted" then
            SubscriptionQueries.updateStatusByStripeId(obj.id, obj.status, obj.current_period_end)

        elseif t == "account.updated" then
            if obj.id then
                local status = (obj.details_submitted and obj.charges_enabled) and "complete" or "pending"
                pcall(function()
                    db.query("UPDATE creator_accounts SET charges_enabled = ?, payouts_enabled = ?, onboarding_status = ?, updated_at = NOW() WHERE stripe_account_id = ?",
                        obj.charges_enabled and true or false, obj.payouts_enabled and true or false, status, obj.id)
                end)
            end
        end

        return { status = 200, json = { received = true } }
    end)
end
