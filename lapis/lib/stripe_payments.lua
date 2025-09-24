local payments = require("payments.stripe")
local Global = require("helper.global")

local StripePayments = {}
StripePayments.__index = StripePayments

function StripePayments.new()
    local self = setmetatable({}, StripePayments)
    
    local api_key = Global.getEnvVar("STRIPE_SECRET_KEY")
    if not api_key then
        error("STRIPE_SECRET_KEY environment variable is required")
    end
    
    -- Create Stripe client using lua-payments
    self.stripe = payments.Stripe({
        client_id = nil, -- Not needed for server-side
        client_secret = api_key,
        sandbox = false -- Set to true for test mode
    })
    
    return self
end

-- Create Payment Intent
function StripePayments:create_payment_intent(amount, currency, options)
    currency = currency or "usd"
    options = options or {}
    
    -- Amount must be in cents for Stripe
    local amount_cents = math.floor(amount * 100)
    
    local params = {
        amount = amount_cents,
        currency = currency,
        automatic_payment_methods = {
            enabled = true
        }
    }
    
    -- Add optional parameters
    if options.customer then
        params.customer = options.customer
    end
    
    if options.metadata then
        params.metadata = options.metadata
    end
    
    if options.description then
        params.description = options.description
    end
    
    if options.receipt_email then
        params.receipt_email = options.receipt_email
    end
    
    -- Use the charge method as per lua-payments documentation
    local success, result = pcall(function()
        return self.stripe:charge({
            amount = amount_cents,
            currency = currency,
            source = "tok_visa", -- This will be replaced by payment method from frontend
            description = options.description or "Payment",
            metadata = options.metadata
        })
    end)
    
    if not success then
        return nil, "Failed to create payment: " .. tostring(result)
    end
    
    return result, nil
end

-- For Payment Intents, we'll use a different approach since lua-payments uses older Stripe API
function StripePayments:create_charge(amount, currency, source, options)
    currency = currency or "usd"
    options = options or {}
    
    -- Amount must be in cents for Stripe
    local amount_cents = math.floor(amount * 100)
    
    local charge_params = {
        amount = amount_cents,
        currency = currency,
        source = source,
        description = options.description or "Payment"
    }
    
    if options.metadata then
        charge_params.metadata = options.metadata
    end
    
    if options.receipt_email then
        charge_params.receipt_email = options.receipt_email
    end
    
    local success, result = pcall(function()
        return self.stripe:charge(charge_params)
    end)
    
    if not success then
        return nil, "Failed to create charge: " .. tostring(result)
    end
    
    return result, nil
end

-- Create Customer
function StripePayments:create_customer(email, name, options)
    options = options or {}
    
    local params = {
        email = email
    }
    
    if name then
        params.description = name -- lua-payments uses description for name
    end
    
    if options.metadata then
        params.metadata = options.metadata
    end
    
    local success, result = pcall(function()
        return self.stripe:create_customer(params)
    end)
    
    if not success then
        return nil, "Failed to create customer: " .. tostring(result)
    end
    
    return result, nil
end

return StripePayments