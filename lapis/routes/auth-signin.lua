--[[
    Hosted sign-in routes: GET /auth/signin and GET /auth/signout.
    The flow and the reasoning are in lib/hosted-signin.lua.
]]

local HostedSignin = require("lib.hosted-signin")
local Cors = require("middleware.cors")
local Global = require("helper.global")
local RateLimit = require("middleware.rate-limit")

-- Page loads only: the sign-in itself is limited (and locked out) by
-- /auth/login and /auth/2fa/verify, which the page calls.
local SIGNIN_LIMIT = { rate = 20, window = 60, prefix = "auth:signin" }

-- The origins trusted beyond CORS_ALLOWED_DOMAINS: the same list /auth/google
-- uses for its frontend_url (routes/auth.lua get_allowed_reset_origins), minus
-- its localhost fallback for unconfigured dev setups: this page hands out a
-- token without a prompt, so nothing is trusted that wasn't configured.
local function extra_origins()
    local origins = {}
    local raw = os.getenv("PASSWORD_RESET_ALLOWED_ORIGINS")
    if raw and raw ~= "" then
        for origin in raw:gmatch("[^,]+") do
            local trimmed = origin:match("^%s*(.-)%s*$")
            if trimmed ~= "" then origins[trimmed] = true end
        end
    end
    local fallback = os.getenv("FRONTEND_URL")
    if fallback and fallback ~= "" then origins[fallback] = true end
    return origins
end

local function trusted(url)
    return Cors.trustedFrontend(url, extra_origins())
end

local function google_configured()
    local id = Global.getEnvVar("GOOGLE_CLIENT_ID")
    return id ~= nil and id ~= "" and not id:find("REPLACE_ME", 1, true)
        and (Global.getEnvVar("GOOGLE_REDIRECT_URI") or "") ~= ""
end

local function nonce()
    local bytes = require("resty.random").bytes(16, true) or require("resty.random").bytes(16)
    return require("resty.string").to_hex(bytes)
end

local function page(status, opts)
    opts.nonce = nonce()
    return {
        status = status,
        layout = false,
        content_type = "text/html; charset=utf-8",
        headers = HostedSignin.headers(opts.nonce),
        HostedSignin.render(opts),
    }
end

return function(app)
    app:get("/auth/signin", RateLimit.wrap(SIGNIN_LIMIT, function(self)
        local ctx, err = HostedSignin.resolve(self.params, trusted)
        if not ctx then
            return page(400, { mode = "error", error = err })
        end
        return page(200, { mode = "signin", ctx = ctx, google = google_configured() })
    end))

    app:get("/auth/signout", RateLimit.wrap(SIGNIN_LIMIT, function(self)
        local ctx, err = HostedSignin.resolve({ frontend_url = self.params.frontend_url }, trusted)
        if not ctx then
            return page(400, { mode = "error", error = err })
        end
        return page(200, { mode = "signout", ctx = ctx })
    end))
end
