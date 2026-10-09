--[[
    Billing & Entitlements — Stripe Connect and the Stripe webhook
    (docs/BILLING_ENTITLEMENTS.md §10, §13; lib/billing-stripe.lua)

      GET  /api/v2/billing/connect              billing.read    the workspace's Stripe account
      POST /api/v2/billing/connect/onboard      billing.manage  { country? } -> { url } (Stripe onboarding)
      POST /api/v2/public/billing/stripe/webhook                Stripe events (signed)

    The webhook is the only place payments change the database. Register it in
    Stripe twice — once for the platform's own events (checkout, subscriptions,
    charges) and once for connected accounts (account.updated) — and put both
    signing secrets in STRIPE_CONNECT_WEBHOOK_SECRET, comma-separated.
]]

local Http = require("helper.field-service-http")
local Stripe = require("lib.stripe")
local Pay = require("lib.billing-stripe")
local Guard = require("lib.billing-guard")
local Webhooks = require("queries.StripeWebhookQueries")

local function raw_body()
    ngx.req.read_body()
    local body = ngx.req.get_body_data()
    if body then return body end
    local file = ngx.req.get_body_file()
    if not file then return nil end
    local f = io.open(file, "rb")
    if not f then return nil end
    body = f:read("*a")
    f:close()
    return body
end

local function verify(payload, signature)
    local last = "STRIPE_CONNECT_WEBHOOK_SECRET is not set"
    for secret in (os.getenv("STRIPE_CONNECT_WEBHOOK_SECRET") or ""):gmatch("[^,%s]+") do
        local event, err = Stripe.construct_event(payload, signature, secret)
        if event then return event end
        last = err
    end
    return nil, last
end

return function(app)
    app:get("/api/v2/billing/connect", Http.guard("billing", "read", function(self)
        return Http.ok(Pay.status(self.namespace.id))
    end))

    app:post("/api/v2/billing/connect/onboard", Http.guard("billing", "manage", function(self)
        local body = Http.json_body() or {}
        local res, err = Pay.onboard(self.namespace.id, body)
        if not res then return Guard.fail(err.status, err.code, err.message) end
        return Http.ok(res)
    end))

    app:post("/api/v2/public/billing/stripe/webhook", function(self)
        local payload = raw_body()
        local event, verr = verify(payload, self.req.headers["stripe-signature"])
        if not event then
            ngx.log(ngx.WARN, "[billing] rejected Stripe webhook: ", tostring(verr))
            return { status = 400, json = { success = false, error = "invalid signature" } }
        end
        -- Test events to a live deployment (or the reverse) are a misconfigured endpoint.
        if event.livemode ~= nil and (event.livemode == true) ~= (Pay.mode() == "live") then
            ngx.log(ngx.WARN, "[billing] Stripe event ", tostring(event.id), " is livemode=", tostring(event.livemode),
                " but this deployment runs in ", Pay.mode(), " mode")
            return { status = 400, json = { success = false, error = "event mode does not match this deployment" } }
        end
        -- Its own id space: the tax app's webhook may see the same platform events.
        local id = "billing:" .. tostring(event.id)
        local status = Webhooks.beginProcessing({ event_id = id, event_type = event.type,
            api_version = event.api_version, livemode = event.livemode, payload = { id = event.id, type = event.type } })
        if status == "processed" or status == "ignored" then
            return { status = 200, json = { received = true, duplicate = true } }
        end
        local ok, res = pcall(Pay.handle, event)
        if not ok then
            ngx.log(ngx.ERR, "[billing] Stripe event ", tostring(event.id), " (", tostring(event.type), ") failed: ",
                tostring(res))
            Webhooks.markFailed(id, res)
            return { status = 500, json = { received = false } }
        end
        if res == "ignored" then Webhooks.markIgnored(id) else Webhooks.markProcessed(id) end
        return { status = 200, json = { received = true } }
    end)
end
