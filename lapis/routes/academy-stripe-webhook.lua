--[[
    Academy Stripe Webhook
    ======================
    POST /api/v2/public/academy/stripe/webhook  (no auth; signature-verified)

    Source of truth for granting access + recording the earnings ledger. All
    charges are on the PLATFORM account (no Connect); the creator's cut/net is
    computed by PayoutQueries.recordSale using their effective fee %.
      - checkout.session.completed (course)       -> enroll + ledger entry
      - checkout.session.completed (subscription) -> create sub + first ledger entry
      - invoice.paid (subscription_cycle)         -> extend sub + renewal ledger entry
      - customer.subscription.updated/deleted     -> update status/period
]]

local Stripe = require("lib.stripe")
local Global = require("helper.global")
local db = require("lapis.db")
local EnrollmentQueries = require("queries.EnrollmentQueries")
local SubscriptionQueries = require("queries.SubscriptionQueries")
local PayoutQueries = require("queries.PayoutQueries")
local CourseQueries = require("queries.CourseQueries")

return function(app)
    -- Idempotency: true if already handled. Inserts the marker; a unique-violation
    -- race also counts as "already processed".
    local function already_processed(event_id, etype)
        local rows = db.query("SELECT 1 FROM processed_stripe_events WHERE event_id = ? LIMIT 1", event_id)
        if rows and #rows > 0 then return true end
        local ok = pcall(function()
            db.query("INSERT INTO processed_stripe_events (event_id, type, created_at) VALUES (?, ?, NOW())",
                event_id, etype)
        end)
        return not ok
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
                -- Attribute the sale to the course owner (the instructor). Legacy /
                -- admin-owned courses may have no owner -> platform revenue.
                local course = CourseQueries.findById(ns_id, tonumber(md.course_id))
                PayoutQueries.recordSale({
                    user_uuid = md.user_uuid, namespace_id = ns_id, course_id = tonumber(md.course_id),
                    seller_user_uuid = course and course.owner_user_uuid or nil,
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
                -- First payment: record the ledger entry here (renewals come via invoice.paid).
                PayoutQueries.recordSale({
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
                -- Renewals only — the first invoice is already recorded at checkout.
                if obj.billing_reason == "subscription_cycle" then
                    local sub = SubscriptionQueries.findByStripeId(obj.subscription)
                    if sub then
                        PayoutQueries.recordSale({
                            user_uuid = sub.user_uuid, namespace_id = sub.namespace_id, kind = "subscription",
                            stripe_ref = obj.id, amount = obj.amount_paid or obj.amount_due, currency = obj.currency,
                        })
                    end
                end
            end

        elseif t == "customer.subscription.updated" or t == "customer.subscription.deleted" then
            SubscriptionQueries.updateStatusByStripeId(obj.id, obj.status, obj.current_period_end)
        end

        return { status = 200, json = { received = true } }
    end)
end
