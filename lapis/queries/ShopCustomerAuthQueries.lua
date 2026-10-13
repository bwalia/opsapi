-- luacheck: max line length 140
--[[
    Shop customer sign-in (Google / Apple)
    ======================================
    Rules live in lib/shop-customer-auth.lua. This module builds the provider
    authorize URL (POST /api/v2/public/shop/:ns/auth/start, BFF only) and, from
    the provider callbacks in routes/auth.lua, turns a verified email into a
    one-time shop sign-in link (the same link + ws_member session the emailed
    VIP sign-in uses). Customers never get a users row or namespace membership.
]]

local cJson = require("cjson")
local Global = require("helper.global")
local U = require("lib.shop-util")
local R = require("lib.shop-membership")
local A = require("lib.shop-customer-auth")

local Q = {}

--- { provider, nonce, next } → { authorize_url }
function Q.start(ns, body)
    local state, reason = A.build_state(ns.slug, body)
    if not state then return nil, U.err(400, "VALIDATION_ERROR", "Invalid sign-in request (" .. reason .. ")") end
    local encoded = cJson.encode(state)

    if body.provider == "google" then
        local client_id = Global.getEnvVar("GOOGLE_CLIENT_ID")
        local redirect_uri = Global.getEnvVar("GOOGLE_REDIRECT_URI")
        if not client_id or not redirect_uri then
            return nil, U.err(503, "PROVIDER_NOT_CONFIGURED", "Google sign-in is not available right now")
        end
        return { authorize_url = A.google_authorize_url(client_id, redirect_uri, encoded) }
    end

    local AppleSignIn = require("helper.apple-signin")
    if not AppleSignIn.is_configured_for_web() then
        return nil, U.err(503, "PROVIDER_NOT_CONFIGURED", "Apple sign-in is not available right now")
    end
    local url, err = AppleSignIn.build_authorize_url(encoded)
    if not url then return nil, U.err(503, "PROVIDER_NOT_CONFIGURED", err or "Apple sign-in is not available right now") end
    return { authorize_url = url }
end

--- Shop base URL the browser goes back to (this deploy's shop).
function Q.shopUrl()
    return U.env("SHOP_PUBLIC_URL")
end

--- Called from the provider callback once the provider has vouched for `email`. Returns the redirect URL.
-- An unverified email is refused: quotes are matched on email, so it must be the customer's own.
function Q.finish(shop_state, email, email_verified)
    local base = Q.shopUrl()
    if not base then
        ngx.log(ngx.ERR, "[shop-sign-in] SHOP_PUBLIC_URL is not set — cannot return to the shop")
        return nil
    end
    local normalised = R.email(email)
    if not normalised then return A.error_url(base, "no_email") end
    if email_verified ~= true then return A.error_url(base, "email_unverified") end

    local ns = require("queries.ShopCatalogQueries").namespaceBySlug(shop_state.ns)
    if not ns then return A.error_url(base, "shop_not_found") end

    local token = require("queries.ShopMembershipQueries").issueSignInLink(ns.id, normalised)
    return A.landing_url(base, token, shop_state)
end

--- Error redirect for a shop sign-in that failed before the provider vouched for anyone.
function Q.errorUrl(code)
    local base = Q.shopUrl()
    return base and A.error_url(base, code) or nil
end

return Q
