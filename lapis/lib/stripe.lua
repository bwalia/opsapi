local http = require("resty.http")
local cjson = require("cjson")
local Global = require("helper.global")

local Stripe = {}
Stripe.__index = Stripe

-- Construct a Stripe API client for the single platform merchant.
--   opts.api_key  override the secret key (defaults to STRIPE_SECRET_KEY env)
function Stripe.new(opts)
    opts = opts or {}
    local self = setmetatable({}, Stripe)
    self.api_key = opts.api_key or Global.getEnvVar("STRIPE_SECRET_KEY")
    self.base_url = "https://api.stripe.com/v1"

    if not self.api_key then
        error("Stripe secret key is required (pass opts.api_key or set STRIPE_SECRET_KEY)")
    end

    return self
end

-- Helper function to convert table to form-encoded string
function Stripe:_encode_table(data, prefix)
    local params = {}

    for k, v in pairs(data) do
        local key = prefix and (prefix .. "[" .. k .. "]") or k

        if type(v) == "table" then
            -- Handle arrays (tables with numeric indices)
            if #v > 0 then
                for i, item in ipairs(v) do
                    local array_key = key .. "[" .. (i-1) .. "]"
                    if type(item) == "table" then
                        local sub_params = self:_encode_table(item, array_key)
                        for _, param in ipairs(sub_params) do
                            table.insert(params, param)
                        end
                    else
                        table.insert(params, ngx.escape_uri(array_key) .. "=" .. ngx.escape_uri(tostring(item)))
                    end
                end
            else
                -- Handle objects (tables with string keys)
                local sub_params = self:_encode_table(v, key)
                for _, param in ipairs(sub_params) do
                    table.insert(params, param)
                end
            end
        else
            table.insert(params, ngx.escape_uri(key) .. "=" .. ngx.escape_uri(tostring(v)))
        end
    end

    return params
end

function Stripe:_request(method, endpoint, data, idempotency_key)
    local httpc = http.new()
    httpc:set_timeout(30000) -- 30 second timeout

    local url = self.base_url .. endpoint
    local headers = {
        ["Authorization"] = "Bearer " .. self.api_key,
        ["Content-Type"] = "application/x-www-form-urlencoded",
        ["Stripe-Version"] = "2023-10-16"
    }

    -- Idempotency key — pass one on retryable writes to avoid double charges.
    if idempotency_key then
        headers["Idempotency-Key"] = idempotency_key
    end

    local body = ""
    if data then
        local params = self:_encode_table(data)
        body = table.concat(params, "&")
    end

    -- TLS peer verification for outbound Stripe calls. Disabled by default to
    -- match the current deployment, which has no CA trust store configured (no
    -- lua_ssl_trusted_certificate in nginx.conf, no ca-certificates in the
    -- image). Turning it on without that store would fail every Stripe call.
    -- To enable — strongly recommended for production — configure the CA bundle
    -- in the image + nginx, then set STRIPE_SSL_VERIFY=true. Kept as a config
    -- switch so enabling it is a deploy-time change, not a code change.
    local ssl_verify = Global.getEnvVar("STRIPE_SSL_VERIFY") == "true"

    -- Minimal logging by default; full request/response bodies (which can carry
    -- PII) are logged only when STRIPE_DEBUG=true.
    local debug_log = Global.getEnvVar("STRIPE_DEBUG") == "true"
    ngx.log(ngx.INFO, "Stripe API Request: " .. method .. " " .. endpoint)
    if debug_log then
        ngx.log(ngx.INFO, "Stripe API Body: " .. body)
    end

    local res, err = httpc:request_uri(url, {
        method = method,
        body = body,
        headers = headers,
        ssl_verify = ssl_verify
    })

    if not res then
        ngx.log(ngx.ERR, "Stripe HTTP request failed: " .. (err or "unknown error"))
        return nil, "HTTP request failed: " .. (err or "unknown error")
    end

    ngx.log(ngx.INFO, "Stripe API Response Status: " .. res.status)
    if debug_log then
        ngx.log(ngx.INFO, "Stripe API Response Body: " .. (res.body or "empty"))
    end

    local response_data
    local ok, decode_err = pcall(function()
        response_data = cjson.decode(res.body)
    end)

    if not ok then
        ngx.log(ngx.ERR, "Failed to decode Stripe JSON response: " .. (decode_err or "unknown error"))
        ngx.log(ngx.ERR, "Raw response body: " .. (res.body or "empty"))
        return nil, "Failed to decode JSON response: " .. (decode_err or "unknown error")
    end

    if res.status >= 400 then
        local error_msg = "Stripe API error"
        if response_data and response_data.error then
            error_msg = response_data.error.message or response_data.error.type or error_msg
        end
        ngx.log(ngx.ERR, "Stripe API error: " .. error_msg)
        return nil, error_msg, response_data
    end

    return response_data, nil
end

-- Create a Checkout Session (Hosted Checkout)
function Stripe:create_checkout_session(options)
    options = options or {}

    local data = {}

    -- Required parameters
    if options.mode then
        data.mode = options.mode
    end

    if options.success_url then
        data.success_url = options.success_url
    end

    if options.cancel_url then
        data.cancel_url = options.cancel_url
    end

    if options.line_items then
        data.line_items = options.line_items
    end

    -- Optional parameters
    if options.customer_email then
        data.customer_email = options.customer_email
    end

    if options.metadata then
        data.metadata = options.metadata
    end

    if options.billing_address_collection then
        data.billing_address_collection = options.billing_address_collection
    end

    if options.shipping_address_collection then
        data.shipping_address_collection = options.shipping_address_collection
    end

    if options.automatic_tax then
        data.automatic_tax = options.automatic_tax
    end

    -- Connect + subscription/one-time pass-throughs:
    --   subscription_data   { application_fee_percent, transfer_data = { destination }, metadata }
    --   payment_intent_data { application_fee_amount, transfer_data = { destination }, metadata }
    --   customer / client_reference_id / allow_promotion_codes
    if options.customer then data.customer = options.customer end
    if options.client_reference_id then data.client_reference_id = options.client_reference_id end
    if options.subscription_data then data.subscription_data = options.subscription_data end
    if options.payment_intent_data then data.payment_intent_data = options.payment_intent_data end
    if options.allow_promotion_codes ~= nil then data.allow_promotion_codes = options.allow_promotion_codes end

    return self:_request("POST", "/checkout/sessions", data, options.idempotency_key)
end

-- Create a Payment Intent (keeping for compatibility)
function Stripe:create_payment_intent(amount, currency, options)
    currency = currency or "usd"
    options = options or {}

    -- Amount must be in cents for Stripe
    local amount_cents = math.floor(amount * 100)

    local data = {
        amount = amount_cents,
        currency = currency,
        automatic_payment_methods = {
            enabled = true
        }
    }

    -- Add optional parameters
    if options.customer then
        data.customer = options.customer
    end

    if options.metadata then
        data.metadata = options.metadata
    end

    if options.description then
        data.description = options.description
    end

    if options.receipt_email then
        data.receipt_email = options.receipt_email
    end

    return self:_request("POST", "/payment_intents", data)
end

-- Create a PaymentIntent on the platform account. Amount is in MINOR units
-- (e.g. 599 = £5.99) — NOT multiplied. Used by the native mobile Payment Sheet
-- for one-time purchases. options: amount, currency, customer, metadata,
-- receipt_email, description, idempotency_key.
function Stripe:create_payment_intent_minor(options)
    options = options or {}
    local data = {
        amount = math.floor(tonumber(options.amount) or 0),
        currency = options.currency or "gbp",
        automatic_payment_methods = { enabled = true },
    }
    if options.customer then data.customer = options.customer end
    if options.metadata then data.metadata = options.metadata end
    if options.receipt_email then data.receipt_email = options.receipt_email end
    if options.description then data.description = options.description end
    return self:_request("POST", "/payment_intents", data, options.idempotency_key)
end

-- Retrieve a Payment Intent
function Stripe:retrieve_payment_intent(payment_intent_id)
    return self:_request("GET", "/payment_intents/" .. payment_intent_id, nil)
end

-- Retrieve a Checkout Session
function Stripe:retrieve_checkout_session(session_id)
    -- Always expand customer_details to get the billing address
    local url = "/checkout/sessions/" .. session_id .. "?expand[]=customer_details"
    return self:_request("GET", url, nil)
end

-- Retrieve a Subscription.
function Stripe:retrieve_subscription(subscription_id)
    return self:_request("GET", "/subscriptions/" .. subscription_id, nil)
end

-- Cancel a Subscription. Default is graceful (at period end — the user keeps
-- access until the paid period runs out); pass at_period_end=false to end now.
function Stripe:cancel_subscription(subscription_id, at_period_end)
    if at_period_end == false then
        return self:_request("DELETE", "/subscriptions/" .. subscription_id, nil)
    end
    return self:_request("POST", "/subscriptions/" .. subscription_id, { cancel_at_period_end = true })
end

-- Create a Customer
function Stripe:create_customer(email, name, options)
    options = options or {}

    local data = {
        email = email
    }

    if name then
        data.name = name
    end

    if options.phone then
        data.phone = options.phone
    end

    if options.address then
        data.address = options.address
    end

    if options.metadata then
        data.metadata = options.metadata
    end

    return self:_request("POST", "/customers", data)
end

-- =========================================================================
-- Products & Prices (the plan catalogue). Created on the platform account.
-- =========================================================================

-- Create a Product. options: name (required), description, active, metadata.
function Stripe:create_product(options)
    options = options or {}
    local data = { name = options.name }
    if options.description and options.description ~= "" then data.description = options.description end
    if options.active ~= nil then data.active = options.active end
    if options.metadata then data.metadata = options.metadata end
    return self:_request("POST", "/products", data, options.idempotency_key)
end

-- Create a Price. options: product (required), unit_amount (MINOR units),
-- currency, recurring = { interval, interval_count } for subscriptions,
-- nickname, metadata. Prices are immutable in Stripe — to change an amount,
-- create a new Price and repoint the plan.
function Stripe:create_price(options)
    options = options or {}
    local data = {
        product = options.product,
        unit_amount = options.unit_amount,
        currency = options.currency or "gbp",
    }
    if options.recurring then data.recurring = options.recurring end
    if options.nickname then data.nickname = options.nickname end
    if options.metadata then data.metadata = options.metadata end
    return self:_request("POST", "/prices", data, options.idempotency_key)
end

-- Update mutable fields on a Product (e.g. name, description, active=false to archive).
function Stripe:update_product(product_id, fields)
    return self:_request("POST", "/products/" .. product_id, fields or {})
end

-- Update mutable fields on a Price (only `active`, `nickname`, `metadata` are mutable).
function Stripe:update_price(price_id, fields)
    return self:_request("POST", "/prices/" .. price_id, fields or {})
end

-- =========================================================================
-- Webhook signature verification (module-level — runs before we know the
-- connected account, so it does not need a client instance)
-- =========================================================================

-- Constant-time comparison to avoid leaking signature info via timing.
function Stripe._secure_compare(a, b)
    if type(a) ~= "string" or type(b) ~= "string" then return false end
    if #a ~= #b then return false end
    local diff = 0
    for i = 1, #a do
        diff = bit.bor(diff, bit.bxor(a:byte(i), b:byte(i)))
    end
    return diff == 0
end

-- Verify a Stripe webhook and return the decoded event.
--   payload         the RAW request body (must be the exact bytes Stripe sent)
--   sig_header      the Stripe-Signature header ("t=...,v1=...")
--   webhook_secret  the endpoint's signing secret (whsec_...)
--   tolerance       max age in seconds (default 300) — replay protection
-- Returns (event_table, nil) on success or (nil, error_message) on failure.
function Stripe.construct_event(payload, sig_header, webhook_secret, tolerance)
    if not payload or payload == "" then return nil, "empty payload" end
    if not sig_header or sig_header == "" then return nil, "missing Stripe-Signature header" end
    if not webhook_secret or webhook_secret == "" then return nil, "webhook secret not configured" end
    tolerance = tolerance or 300

    -- Parse "t=<ts>,v1=<sig>,v1=<sig>"
    local timestamp
    local v1_sigs = {}
    for part in sig_header:gmatch("[^,]+") do
        local k, v = part:match("^%s*(%w+)%s*=%s*(.+)%s*$")
        if k == "t" then
            timestamp = tonumber(v)
        elseif k == "v1" then
            table.insert(v1_sigs, v)
        end
    end
    if not timestamp then return nil, "no timestamp in signature header" end
    if #v1_sigs == 0 then return nil, "no v1 signature in header" end

    -- Replay protection.
    if math.abs(ngx.time() - timestamp) > tolerance then
        return nil, "timestamp outside tolerance"
    end

    -- Expected signature = HMAC-SHA256(secret, "<timestamp>.<payload>"), hex.
    local ok_hmac, hmac = pcall(require, "resty.openssl.hmac")
    if not ok_hmac then return nil, "hmac library unavailable" end
    local h, herr = hmac.new(webhook_secret, "sha256")
    if not h then return nil, "hmac init failed: " .. tostring(herr) end
    if not h:update(tostring(timestamp) .. "." .. payload) then
        return nil, "hmac update failed"
    end
    local mac = h:final()
    local expected = mac:gsub(".", function(c) return string.format("%02x", string.byte(c)) end)

    local matched = false
    for _, sig in ipairs(v1_sigs) do
        if Stripe._secure_compare(expected, sig) then
            matched = true
            break
        end
    end
    if not matched then return nil, "signature verification failed" end

    local ok_decode, event = pcall(cjson.decode, payload)
    if not ok_decode then return nil, "failed to decode event payload" end
    return event, nil
end

return Stripe