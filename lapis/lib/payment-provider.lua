--[[
    Payment Provider abstraction + dynamic configuration
    =====================================================

    Single place that resolves *how* payment-provider credentials are obtained,
    so no other module reads STRIPE_* env vars directly. Configuration is
    environment-driven and mode-aware (test | live): switching sandbox <-> live
    is a config change, never a code change.

    Per-tenant model (Stripe Connect): there is ONE platform secret key. Each
    tenant is a connected account (acct_...) addressed via destination charges
    or the Stripe-Account header. This module returns a Stripe client configured
    for the platform, or for a given connected account.

    Provider-agnostic by design: Wise (bank transfer) slots in behind the same
    `get(provider)` surface in a later phase with no caller changes.

    All functions fail soft — they return (value, nil) or (nil, error_message)
    rather than throwing — so route handlers can respond with a clean error.
]]

local Global = require("helper.global")
local Stripe = require("lib.stripe")

local PaymentProvider = {}

-- =========================================================================
-- Stripe configuration (dynamic, mode-aware)
-- =========================================================================

-- Active Stripe mode: 'test' | 'live'. Inferred from the STRIPE_SECRET_KEY
-- prefix (sk_live_ / rk_live_ → live), so there is no separate STRIPE_MODE
-- variable to manage — the single key determines the mode. Swap the key to
-- switch between test and live.
function PaymentProvider.stripe_mode()
    local key = Global.getEnvVar("STRIPE_SECRET_KEY") or ""
    if key:find("_live_", 1, true) then return "live" end
    return "test"
end

-- Resolve the platform Stripe config. One set of variables only:
--   STRIPE_SECRET_KEY · STRIPE_PUBLISHABLE_KEY · STRIPE_WEBHOOK_SECRET
-- (STRIPE_CONNECT_WEBHOOK_SECRET and STRIPE_PLATFORM_FEE_PERCENT are optional
-- and fall back gracefully). No test/live key variants.
function PaymentProvider.stripe_config()
    return {
        mode = PaymentProvider.stripe_mode(),
        secret_key = Global.getEnvVar("STRIPE_SECRET_KEY"),
        publishable_key = Global.getEnvVar("STRIPE_PUBLISHABLE_KEY"),
        webhook_secret = Global.getEnvVar("STRIPE_WEBHOOK_SECRET"),
    }
end

-- Whether Stripe is usable (a secret key is present for the active mode).
-- Routes call this to return a clean 503 instead of risking a throw.
function PaymentProvider.stripe_configured()
    local cfg = PaymentProvider.stripe_config()
    return cfg.secret_key ~= nil and cfg.secret_key ~= ""
end

-- Return a Stripe client for the platform account (the single merchant defined
-- by STRIPE_SECRET_KEY). Returns (client, nil) or (nil, error).
function PaymentProvider.get_stripe()
    local cfg = PaymentProvider.stripe_config()
    if not cfg.secret_key or cfg.secret_key == "" then
        return nil, "Stripe is not configured (missing STRIPE_SECRET_KEY)"
    end

    local ok, client = pcall(Stripe.new, { api_key = cfg.secret_key })
    if not ok then
        return nil, "Failed to initialise Stripe client: " .. tostring(client)
    end
    return client, nil
end

-- =========================================================================
-- Provider abstraction (Wise-ready)
-- =========================================================================

local PROVIDERS = {
    stripe = {
        name = "stripe",
        configured = function() return PaymentProvider.stripe_configured() end,
        get_client = function() return PaymentProvider.get_stripe() end,
    },
    -- wise = { ... }  -- slots in during the Wise phase, same surface.
}

-- Look up a provider adapter by name (defaults to stripe).
function PaymentProvider.get(provider_name)
    provider_name = provider_name or "stripe"
    local p = PROVIDERS[provider_name]
    if not p then
        return nil, "Unknown or unsupported payment provider: " .. tostring(provider_name)
    end
    return p, nil
end

return PaymentProvider
