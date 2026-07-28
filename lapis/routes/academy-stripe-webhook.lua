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
    -- Idempotency, part 1 (read-only): has this event already been fully
    -- processed and committed? The marker is written LAST, inside the same
    -- transaction as the side effects (see below), so its presence guarantees
    -- the side effects landed. A missing marker means genuine reprocessing is
    -- safe — which is exactly what we want after a mid-handler failure.
    local function is_processed(event_id)
        local rows = db.query("SELECT 1 FROM processed_stripe_events WHERE event_id = ? LIMIT 1", event_id)
        return rows ~= nil and #rows > 0
    end

    -- Idempotency, part 2 (write): mark the event processed. Called as the FINAL
    -- statement inside the side-effect transaction. The unique index on event_id
    -- doubles as the concurrency guard: if two deliveries of the same event race,
    -- one INSERT blocks then raises a unique violation, aborting that whole
    -- transaction (rolling back its partial side effects) — so a duplicate can
    -- never write the ledger twice.
    local function mark_processed(event_id, etype)
        db.query("INSERT INTO processed_stripe_events (event_id, type, created_at) VALUES (?, ?, NOW())",
            event_id, etype)
    end

    -- Run fn inside a DB transaction. Any error (from a side effect OR the marker
    -- INSERT) rolls back EVERYTHING — including the idempotency marker — so the
    -- event stays un-marked and Stripe's retry genuinely reprocesses it. Returns
    -- (true) on commit, or (false, err) on rollback.
    local function in_transaction(fn)
        db.query("BEGIN")
        local ok, err = pcall(fn)
        if ok then
            db.query("COMMIT")
            return true
        end
        pcall(function() db.query("ROLLBACK") end)
        return false, err
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

        -- Genuine duplicate (already committed) — short-circuit. A missing marker
        -- after an earlier failure is NOT a duplicate: we fall through and reprocess.
        if is_processed(event.id) then
            return { status = 200, json = { received = true, duplicate = true } }
        end

        local obj = (event.data and event.data.object) or {}
        local t = event.type

        -- Fetch any external Stripe data BEFORE opening the transaction: a Stripe
        -- HTTP round-trip must not hold a DB transaction (and its row locks) open.
        -- A failed fetch here just means the sub object stays nil; we degrade the
        -- same way the original code did (default status "active", no period end).
        local subobj = nil
        local need_sub =
            (t == "checkout.session.completed" and (obj.metadata or {}).kind == "subscription" and obj.subscription) or
            (t == "invoice.paid" and obj.subscription)
        if need_sub then
            local ok_fetch, res = pcall(function() return Stripe.new():retrieve_subscription(obj.subscription) end)
            if ok_fetch then subobj = res end
        end

        -- All persistent side effects run inside ONE transaction, and the
        -- idempotency marker is written as its LAST statement. Any failure rolls
        -- back the marker together with the partial side effects, so nothing is
        -- half-written and Stripe's retry reprocesses the whole event cleanly.
        local ok, err = in_transaction(function()
            if t == "checkout.session.completed" then
                local md = obj.metadata or {}
                local ns_id = tonumber(md.namespace_id)
                if md.kind == "course" and ns_id and tonumber(md.course_id) and md.user_uuid then
                    -- Enroll + ledger are now atomic: if the ledger write fails the
                    -- enrollment rolls back too, so the buyer is never granted access
                    -- without the instructor's earnings row being recorded.
                    EnrollmentQueries.enroll(ns_id, tonumber(md.course_id), md.user_uuid)
                    -- Attribute the sale to the course owner (the instructor). Legacy /
                    -- admin-owned courses may have no owner -> platform revenue.
                    local course = CourseQueries.findById(ns_id, tonumber(md.course_id))
                    PayoutQueries.recordSale({
                        user_uuid = md.user_uuid, namespace_id = ns_id, course_id = tonumber(md.course_id),
                        seller_user_uuid = course and course.owner_user_uuid or nil,
                        kind = "course", stripe_ref = obj.payment_intent, amount = obj.amount_total, currency = obj.currency,
                    })
                elseif md.kind == "subscription" and ns_id and md.user_uuid and obj.subscription then
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

            -- Idempotency marker LAST — same transaction as the side effects above.
            mark_processed(event.id, t)
        end)

        if not ok then
            -- Marker was rolled back with the side effects: return non-2xx so Stripe
            -- retries and genuinely reprocesses (no silent revenue loss).
            ngx.log(ngx.ERR, "[academy webhook] processing FAILED for event " ..
                tostring(event.id) .. " (" .. tostring(t) .. "): " .. tostring(err) ..
                " — marker NOT written, Stripe will retry")
            return { status = 500, json = { error = "processing failed" } }
        end

        return { status = 200, json = { received = true } }
    end)
end
