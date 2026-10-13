-- luacheck: max line length 140
--[[
    Shop customer sign-in (Google / Apple) — pure rules
    ===================================================
    A shop customer signs in with Google or Apple through OpsAPI's existing
    provider callbacks (/auth/google/callback, /auth/apple/callback), so no new
    redirect URI has to be registered with either provider. The OAuth `state`
    carries a `shop` table instead of the dashboard's frontend_url/project_code:

        { shop = { ns = "<namespace slug>", n = "<nonce>", next = "/account" } }

    When the callback sees it, it does NOT create a users row or a namespace
    membership (customers are not staff). It issues a one-time shop sign-in link
    for the provider-verified email and redirects to the shop, which exchanges
    the link for the same ws_member session the emailed VIP links use.

    The nonce is set by the shop as an httpOnly cookie before the redirect and
    checked when the browser lands back, so a forged state can't sign a victim
    into someone else's account. `next` is only ever a same-site path.

    No nginx, no DB: unit tested by spec/shop-customer-auth-test.lua.
]]

local M = {}

M.PROVIDERS = { google = true, apple = true }
M.DEFAULT_NEXT = "/account"

local function escape(s)
    return (tostring(s):gsub("[^%w%-%._~]", function(c) return ("%%%02X"):format(c:byte()) end))
end
M.escape = escape

--- A nonce the shop generated: 16–128 url-safe characters.
function M.valid_nonce(n)
    return type(n) == "string" and #n >= 16 and #n <= 128 and n:match("^[%w_%-]+$") ~= nil
end

--- A namespace slug as namespaces.slug stores it.
function M.valid_slug(s)
    return type(s) == "string" and #s >= 1 and #s <= 100 and s:match("^[a-z0-9][a-z0-9%-]*$") ~= nil
end

--- Same-site path to land on after sign-in, else /account. Never a scheme, host or protocol-relative URL.
function M.safe_next(p)
    if type(p) ~= "string" or #p == 0 or #p > 200 then return M.DEFAULT_NEXT end
    if p:sub(1, 1) ~= "/" then return M.DEFAULT_NEXT end
    local second = p:sub(2, 2)
    if second == "/" or second == "\\" then return M.DEFAULT_NEXT end
    if not p:match("^[%w%-%._~/%?=&%%#]+$") then return M.DEFAULT_NEXT end
    return p
end

--- State table for the provider round trip, or nil + reason.
function M.build_state(ns_slug, body)
    body = type(body) == "table" and body or {}
    if not M.PROVIDERS[body.provider] then return nil, "unsupported_provider" end
    if not M.valid_slug(ns_slug) then return nil, "invalid_namespace" end
    if not M.valid_nonce(body.nonce) then return nil, "invalid_nonce" end
    return { shop = { ns = ns_slug, n = body.nonce, next = M.safe_next(body.next) } }
end

--- The `shop` part of a decoded callback state, or nil when this is not a shop sign-in (or it is malformed).
function M.from_state(state)
    local s = type(state) == "table" and state.shop or nil
    if type(s) ~= "table" or not M.valid_slug(s.ns) or not M.valid_nonce(s.n) then return nil end
    return { ns = s.ns, nonce = s.n, next = M.safe_next(s.next) }
end

local function base_of(shop_url)
    return (tostring(shop_url):gsub("/+$", ""))
end

--- Where the browser lands with the one-time link: <shop>/account/verify?t=&n=&next=
function M.landing_url(shop_url, link_token, shop_state)
    return ("%s/account/verify?t=%s&n=%s&next=%s"):format(base_of(shop_url), escape(link_token),
        escape(shop_state.nonce), escape(shop_state.next))
end

--- Where the browser lands when sign-in failed: <shop>/login?error=<code>
function M.error_url(shop_url, code)
    return ("%s/login?error=%s"):format(base_of(shop_url), escape(code or "sign_in_failed"))
end

--- Google's authorize URL (same scopes as the dashboard sign-in).
function M.google_authorize_url(client_id, redirect_uri, state)
    return ("https://accounts.google.com/o/oauth2/v2/auth?client_id=%s&redirect_uri=%s"
        .. "&response_type=code&scope=openid+profile+email&prompt=select_account&state=%s")
        :format(escape(client_id), escape(redirect_uri), escape(state))
end

return M
