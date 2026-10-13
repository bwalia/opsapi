-- luacheck: max line length 140
--[[
    Shop customer sign-in (Google / Apple / Facebook / OpsAPI password)
    ===================================================================
    Rules live in lib/shop-customer-auth.lua. This module builds the provider
    authorize URL (POST /api/v2/public/shop/:ns/auth/start, BFF only) and, from
    the provider callbacks in routes/auth.lua, turns a verified email into a
    one-time shop sign-in link (the same link + ws_member session the emailed
    VIP sign-in uses). Customers never get a users row or namespace membership.

    Password sign-in (POST .../auth/password then .../auth/password/verify, BFF
    only) checks an existing OpsAPI account the same way /auth/login does: the
    shared per-account lockout, then a 6-digit code emailed to the account. Only
    the right code gets a shop session, for the account's email.
]]

local cJson = require("cjson")
local Global = require("helper.global")
local U = require("lib.shop-util")
local R = require("lib.shop-membership")
local A = require("lib.shop-customer-auth")
local db = require("lapis.db")
local OTP = require("helper.otp")
local Throttle = require("helper.auth-throttle")

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

    if body.provider == "facebook" then
        local app_id = Global.getEnvVar("FACEBOOK_APP_ID")
        local redirect_uri = Global.getEnvVar("FACEBOOK_REDIRECT_URI")
        if not app_id or not redirect_uri or not Global.getEnvVar("FACEBOOK_APP_SECRET") then
            return nil, U.err(503, "PROVIDER_NOT_CONFIGURED", "Facebook sign-in is not available right now")
        end
        return { authorize_url = A.facebook_authorize_url(app_id, redirect_uri, encoded) }
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

    local Membership = require("queries.ShopMembershipQueries")
    local token, terr = Membership.issueSignInLink(ns.id, normalised)
    if not token then
        local code = (terr and terr.code == "ACCOUNT_CLOSED") and "account_closed" or "sign_in_failed"
        return A.error_url(base, code)
    end
    return A.landing_url(base, token, shop_state)
end

--- Error redirect for a shop sign-in that failed before the provider vouched for anyone.
function Q.errorUrl(code)
    local base = Q.shopUrl()
    return base and A.error_url(base, code) or nil
end

-- Facebook ---------------------------------------------------------------------------

local function graph_get(path, args)
    local http = require("resty.http")
    local httpc = http.new()
    httpc:set_timeout(15000)
    local res, err = httpc:request_uri(A.FACEBOOK_GRAPH .. path .. "?" .. ngx.encode_args(args),
        { method = "GET", ssl_verify = true })
    if not res then return nil, err end
    local ok, data = pcall(cJson.decode, res.body or "")
    if not ok or type(data) ~= "table" then return nil, "bad response (HTTP " .. tostring(res.status) .. ")" end
    if res.status ~= 200 or data.error then
        return nil, type(data.error) == "table" and tostring(data.error.message) or ("HTTP " .. tostring(res.status))
    end
    return data
end

local function appsecret_proof(token, secret)
    local hmac = require("resty.openssl.hmac")
    local h = hmac.new(secret, "sha256")
    h:update(token)
    return (h:final():gsub(".", function(c) return ("%02x"):format(c:byte()) end))
end

--- GET /auth/facebook/callback → the URL to redirect to, or nil when the state is not a shop sign-in.
-- Facebook only returns an email address the person has confirmed with Facebook, so it counts as verified.
function Q.facebookCallback(params)
    local ok, state = pcall(cJson.decode, params.state or "")
    local shop_state = ok and A.from_state(state) or nil
    if not shop_state then return nil end
    if not params.code then return Q.errorUrl(params.error or "missing_code") end

    local app_id = Global.getEnvVar("FACEBOOK_APP_ID")
    local secret = Global.getEnvVar("FACEBOOK_APP_SECRET")
    local redirect_uri = Global.getEnvVar("FACEBOOK_REDIRECT_URI")
    if not app_id or not secret or not redirect_uri then return Q.errorUrl("provider_unavailable") end

    local tok, terr = graph_get("/oauth/access_token", {
        client_id = app_id, client_secret = secret, redirect_uri = redirect_uri, code = params.code,
    })
    if not tok or not tok.access_token then
        ngx.log(ngx.ERR, "[shop-sign-in] Facebook token exchange failed: ", tostring(terr))
        return Q.errorUrl("sign_in_failed")
    end
    local me, merr = graph_get("/me", {
        fields = "id,email", access_token = tok.access_token,
        appsecret_proof = appsecret_proof(tok.access_token, secret),
    })
    if not me then
        ngx.log(ngx.ERR, "[shop-sign-in] Facebook profile fetch failed: ", tostring(merr))
        return Q.errorUrl("sign_in_failed")
    end
    return Q.finish(shop_state, me.email, me.email ~= nil) or Q.errorUrl("sign_in_failed")
end

-- OpsAPI account password ------------------------------------------------------------

-- Same lockout key as /auth/login, so the shop is not a way round it.
local function lock_key(identifier)
    local row = db.query("SELECT uuid FROM users WHERE lower(email) = lower(?) LIMIT 1", identifier)[1]
    return Throttle.key("login", row and row.uuid or identifier)
end

local function locked(retry_after)
    return U.err(429, "AUTH_LOCKED", "Too many failed sign-in attempts. Try again later.", { retry_after = retry_after })
end

--- { email, password } → { session_token, email (masked) }; emails a 6-digit code.
function Q.passwordStart(_, body)
    body = type(body) == "table" and body or {}
    local email = R.email(body.email)
    local password = type(body.password) == "string" and body.password or nil
    if not email or not password or #password == 0 or #password > 200 then
        return nil, U.err(400, "VALIDATION_ERROR", "Please enter your email address and password")
    end

    local key = lock_key(email)
    local is_locked, retry_after = Throttle.blocked(key, Throttle.LOGIN)
    if is_locked then return nil, locked(retry_after) end

    local user = require("queries.UserQueries").verify(email, password)
    if not user then
        Throttle.hit(key, Throttle.LOGIN.window)
        return nil, U.err(401, "INVALID_CREDENTIALS", "That email address and password don't match")
    end
    Throttle.clear(key)

    local sent, send_err = OTP.sendToEmail({ id = user.id, email = user.email, first_name = user.first_name },
        { app_name = "Workstation", header_title = "Workstation shop" })
    if send_err == "rate_limited" then return nil, locked(Throttle.OTP_SEND.window) end
    if not sent then ngx.log(ngx.ERR, "[shop-sign-in] OTP send failed for user ", user.id, ": ", tostring(send_err)) end

    return { session_token = OTP.generateSessionToken(user.uuid, user.id), email = A.mask_email(user.email) }
end

--- { session_token, code } → { session_token, email, expires_in_days } (the ws_member session).
function Q.passwordVerify(ns, body)
    body = type(body) == "table" and body or {}
    if not A.valid_code(body.code) then return nil, U.err(400, "VALIDATION_ERROR", "Please enter the 6-digit code") end
    local session, serr = OTP.verifySessionToken(body.session_token)
    if not session then return nil, U.err(401, "SIGN_IN_EXPIRED", serr or "Please sign in again") end

    local ok, verr = OTP.verify(session.user_id, body.code)
    if not ok then return nil, U.err(401, "INVALID_CODE", verr or "That code isn't right") end

    local row = db.query("SELECT email FROM users WHERE id = ? AND uuid = ?", session.user_id, session.user_uuid)[1]
    local email = row and R.email(row.email)
    if not email then return nil, U.err(401, "SIGN_IN_EXPIRED", "Please sign in again") end

    local Membership = require("queries.ShopMembershipQueries")
    local link, lerr = Membership.issueSignInLink(ns.id, email)
    if not link then return nil, lerr end
    return Membership.verifyLink(ns.id, { token = link })
end

return Q
