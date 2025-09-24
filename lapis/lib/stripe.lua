local http = require("resty.http")
local cjson = require("cjson")
local Global = require("helper.global")

local Stripe = {}
Stripe.__index = Stripe

function Stripe.new()
    local self = setmetatable({}, Stripe)
    self.api_key = Global.getEnvVar("STRIPE_SECRET_KEY")
    self.base_url = "https://api.stripe.com/v1"
    
    if not self.api_key then
        error("STRIPE_SECRET_KEY environment variable is required")
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

    -- Add idempotency key if provided
    if idempotency_key then
        headers["Idempotency-Key"] = idempotency_key
    end

    local body = ""
    if data then
        local params = self:_encode_table(data)
        body = table.concat(params, "&")
    end
    
    -- Log request for debugging
    ngx.log(ngx.INFO, "Stripe API Request: " .. method .. " " .. url)
    ngx.log(ngx.INFO, "Stripe API Body: " .. body)
    
    local res, err = httpc:request_uri(url, {
        method = method,
        body = body,
        headers = headers,
        ssl_verify = false -- Disable SSL verification for debugging
    })
    
    if not res then
        ngx.log(ngx.ERR, "Stripe HTTP request failed: " .. (err or "unknown error"))
        return nil, "HTTP request failed: " .. (err or "unknown error")
    end
    
    -- Log response for debugging
    ngx.log(ngx.INFO, "Stripe API Response Status: " .. res.status)
    ngx.log(ngx.INFO, "Stripe API Response Body: " .. (res.body or "empty"))
    
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

    return self:_request("POST", "/checkout/sessions", data)
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

-- Retrieve a Payment Intent
function Stripe:retrieve_payment_intent(payment_intent_id)
    return self:_request("GET", "/payment_intents/" .. payment_intent_id, nil)
end

-- Retrieve a Checkout Session
function Stripe:retrieve_checkout_session(session_id)
    return self:_request("GET", "/checkout/sessions/" .. session_id, nil)
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

return Stripe