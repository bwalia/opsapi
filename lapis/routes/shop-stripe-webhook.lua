-- luacheck: max line length 140
--[[
    Shop — Stripe webhook
    =====================

    POST /api/v2/public/shop/stripe/webhook   (public, auth-exempt via /public/)

    Structure copied from routes/billing-webhook.lua, with the beaconpulse
    ledger semantics from BUILD.prompt.md §4:
      - STRIPE_SHOP_WEBHOOK_SECRET unset → 404 (shop payments disabled)
      - signature verified over the RAW body (Stripe.construct_event) → 400 if bad
      - ONE transaction: INSERT shop_stripe_events ... ON CONFLICT (event_id)
        DO NOTHING (no row → duplicate → 200), apply, COMMIT, THEN 200
      - handler error → ROLLBACK (ledger row too) → 500 so Stripe retries

    Handled: checkout.session.completed | .async_payment_succeeded | .expired |
             .async_payment_failed, charge.refunded (see queries/ShopStripeQueries.lua)
]]

local Stripe = require("lib.stripe")
local U = require("lib.shop-util")
local ShopStripeQueries = require("queries.ShopStripeQueries")

return function(app)
    app:post("/api/v2/public/shop/stripe/webhook", function()
        local secret = U.env("STRIPE_SHOP_WEBHOOK_SECRET")
        if not secret then
            return { status = 404, json = { success = false, error = "Not found", code = "PAYMENTS_DISABLED" } }
        end

        -- Verify the signature over the RAW body.
        ngx.req.read_body()
        local body = ngx.req.get_body_data()
        if not body then
            local path = ngx.req.get_body_file()
            if path then
                local f = io.open(path, "rb")
                if f then
                    body = f:read("*a")
                    f:close()
                end
            end
        end
        if not body or body == "" then
            return { status = 400, json = { success = false, error = "Empty body", code = "EMPTY_BODY" } }
        end
        local sig = ngx.req.get_headers()["stripe-signature"]
        local event, verr = Stripe.construct_event(body, sig, secret)
        if not event then
            ngx.log(ngx.WARN, "[shop-webhook] signature verification failed: ", tostring(verr))
            return { status = 400, json = { success = false, error = "Invalid signature", code = "INVALID_SIGNATURE" } }
        end

        local ok, res = pcall(ShopStripeQueries.handleEvent, event)
        if not ok then
            ngx.log(ngx.ERR, "[shop-webhook] ", tostring(event.type), " ", tostring(event.id), " failed: ", tostring(res))
            return { status = 500, json = { success = false, error = "Handler failed", code = "HANDLER_FAILED" } }
        end
        -- committed — only now acknowledge
        return { status = 200, json = { received = true, duplicate = res.duplicate, ignored = res.ignored or nil,
                                        order_uuid = res.order_uuid } }
    end)
end
