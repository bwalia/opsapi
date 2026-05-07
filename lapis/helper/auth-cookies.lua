--[[
    Auth Cookies Helper (helper/auth-cookies.lua)

    Reads, writes, and clears the HttpOnly Secure cookie that carries
    the opaque refresh token. Set alongside the JSON ``refresh_token``
    field on /auth/login (so mobile clients keep working) and as the
    *only* refresh-token transport on /auth/google/callback (where
    the response is a redirect — no JSON body to inhabit).

    Why a cookie instead of a URL query param or localStorage:

    * URL query strings leak through server access logs, browser
      history, HTTP Referer headers, browser extensions, browser
      cache, and shoulder-surfing. With a 30-day token lifetime,
      one leak hands an attacker 720× the window of a leaked
      1-hour JWT.
    * localStorage is XSS-readable. Any successful injection on the
      origin extracts every refresh token in the browser. HttpOnly
      cookies are JS-invisible and survive XSS that doesn't have
      service-worker-grade access.
    * ``SameSite=Strict`` cookies are CSRF-safe and still work
      across same-site cross-origin subdomains (``app`` ↔ ``api``).
    * The browser auto-includes the cookie on every request to the
      cookie's Domain — refresh "just works" without the frontend
      ever ferrying the value.

    Cookie attributes:

    * ``HttpOnly``         — JS can't read it (XSS-safe)
    * ``Secure``           — HTTPS-only (omitted only when
                             AUTH_COOKIE_INSECURE=true for plain-HTTP
                             local dev)
    * ``SameSite=Strict``  — CSRF-safe; still works cross-origin
                             within same site
    * ``Path=/``           — sent on every request to the domain
    * ``Domain``           — derived per-request from the calling
                             tenant's Origin (see "Multi-tenant
                             cookie-domain resolution" below). May
                             be omitted entirely (host-scoped) for
                             single-host proxy deployments.
    * ``Max-Age=2592000``  — 30 days, matches RefreshToken expiry

    Multi-tenant cookie-domain resolution
    --------------------------------------

    opsapi is a SaaS product — one deployment serves many tenants on
    different apex domains (``tenant-a.com``, ``acme.io``, ...). A
    static ``AUTH_COOKIE_DOMAIN`` doesn't scale because each tenant
    needs a Domain attribute matching their own eTLD+1.

    The Domain attribute is resolved per-request using this priority:

      1. If ``AUTH_COOKIE_DOMAIN`` is explicitly set, use it verbatim.
         Useful for single-tenant deployments where the operator
         wants one fixed value regardless of incoming Origin.

      2. Else, look up the request's ``Origin`` host against
         ``AUTH_COOKIE_TRUSTED_DOMAINS`` — a comma-separated list of
         apex domains the operator has approved for cookie scoping.
         The longest matching suffix wins, and the cookie is set
         with ``Domain=.<match>``.

      3. Else, omit the Domain attribute entirely. The browser
         scopes the cookie to the request host. This is correct for
         single-host reverse-proxy deployments where the frontend
         and api share an origin (e.g., nginx routing ``/api`` and
         ``/`` to different upstreams under one hostname).

    Tenants typically configure step 2 with one entry per tenant:

        AUTH_COOKIE_TRUSTED_DOMAINS=diytaxreturn.co.uk,tenant-a.com,acme.io

    Adding a new tenant is a single comma-append, no per-tenant
    opsapi instance required.

    CORS prerequisites (handled in nginx, not here):

    1. ``Access-Control-Allow-Credentials: true`` on api responses.
    2. ``Access-Control-Allow-Origin`` echoes the specific request
       origin (never ``*``).

    Frontend must set ``withCredentials: true`` on the API client.
]]

local AuthCookies = {}

-- The cookie name. Stable and human-readable so server logs / cookie
-- inspectors are clear about what's there.
local COOKIE_NAME = "refresh_token"

-- 30 days, mirrors RefreshToken.EXPIRY_SECONDS in helper/refresh-token.lua.
-- Keeping these aligned avoids the cookie outliving the DB row (or
-- vice versa) and producing zombie auth state.
local MAX_AGE_SECONDS = 30 * 24 * 60 * 60

--- Parse the AUTH_COOKIE_TRUSTED_DOMAINS env into a Lua array.
-- Splits on commas, trims whitespace, drops empty entries. Cached on
-- the worker process — env vars don't change without an nginx reload.
local _trusted_domains_cache
local function trusted_domains()
    if _trusted_domains_cache ~= nil then return _trusted_domains_cache end
    local raw = os.getenv("AUTH_COOKIE_TRUSTED_DOMAINS") or ""
    local list = {}
    for entry in raw:gmatch("[^,]+") do
        local clean = entry:gsub("^%s+", ""):gsub("%s+$", "")
        -- Strip an optional leading dot so the operator can paste
        -- either ".tenant.com" or "tenant.com" — we always store
        -- without the dot and add it back when emitting.
        clean = clean:gsub("^%.", "")
        if clean ~= "" then
            list[#list + 1] = clean:lower()
        end
    end
    _trusted_domains_cache = list
    return list
end

--- Extract the hostname from an Origin header value.
-- @param origin string|nil e.g. "https://app.tenant.com:8443"
-- @return string|nil hostname (lowercased) or nil if unparseable
local function origin_to_host(origin)
    if not origin or origin == "" then return nil end
    local host = origin:match("^https?://([^:/]+)")
    if not host then return nil end
    return host:lower()
end

--- Resolve the cookie's Domain attribute for the current request.
-- Returns the value to put after ``Domain=`` (with leading dot), or
-- nil to omit the Domain attribute entirely.
-- @param self table Lapis request context (for header reading)
-- @return string|nil
local function resolve_cookie_domain(self)
    -- 1. Explicit override wins. Operators wanting one fixed value
    --    regardless of Origin can still configure that.
    local override = os.getenv("AUTH_COOKIE_DOMAIN")
    if override and override ~= "" then
        return override  -- emitted verbatim — operator owns the format
    end

    -- 2. Multi-tenant: longest-suffix match against allowlist.
    local list = trusted_domains()
    if #list > 0 and self and self.req and self.req.headers then
        local origin = self.req.headers["Origin"] or self.req.headers["origin"]
        local host = origin_to_host(origin)
        if host then
            local best
            for _, allowed in ipairs(list) do
                -- Match if host ends with ".<allowed>" or equals it.
                -- Equality covers the apex itself ("tenant.com").
                -- Suffix match covers subdomains ("app.tenant.com").
                local matches = host == allowed
                    or host:sub(-(#allowed + 1)) == "." .. allowed
                if matches and (not best or #allowed > #best) then
                    best = allowed
                end
            end
            if best then
                return "." .. best
            end
        end
    end

    -- 3. No allowlist match → omit Domain. Browser scopes to the
    --    request host. Correct for single-host proxy deployments
    --    and for local dev. Wrong (cookie won't be sent on the
    --    other subdomain's requests) for cross-subdomain setups
    --    where the operator forgot to configure the allowlist —
    --    that's a deliberate fail-closed: better a broken refresh
    --    than a cookie that leaks across an unintended domain.
    return nil
end

--- Build the Set-Cookie header value.
-- @param self table|nil Lapis request context (for Origin lookup)
-- @param value string|nil Cookie value (empty for clearing)
-- @param max_age number Cookie max age in seconds (0 to clear)
-- @return string The Set-Cookie header value
local function format_cookie(self, value, max_age)
    local parts = {
        COOKIE_NAME .. "=" .. (value or ""),
        "Path=/",
        "HttpOnly",
        "SameSite=Strict",
        "Max-Age=" .. tostring(max_age or 0),
    }

    local domain = resolve_cookie_domain(self)
    if domain then
        table.insert(parts, "Domain=" .. domain)
    end

    -- Secure default-on. The only way to disable is the explicit
    -- AUTH_COOKIE_INSECURE=true env var, intended for localhost dev
    -- over plain HTTP. NEVER set this in any HTTPS environment.
    if os.getenv("AUTH_COOKIE_INSECURE") ~= "true" then
        table.insert(parts, "Secure")
    end

    return table.concat(parts, "; ")
end

--- Set the refresh-token cookie on the current response.
-- Safe to call from any handler before the response is finalised.
-- No-op when token is empty (so callers don't need to nil-check).
-- @param self table Lapis request context (for Origin-aware Domain)
-- @param token string The opaque refresh token to persist client-side
function AuthCookies.set(self, token)
    if not token or token == "" then return end
    ngx.header["Set-Cookie"] = format_cookie(self, token, MAX_AGE_SECONDS)
end

--- Clear the refresh-token cookie. Used on logout and when the
-- backend has detected the cookie's value is no longer valid (e.g.
-- token revoked, family rotated out).
-- @param self table Lapis request context (for Origin-aware Domain
--             — must match the original Set-Cookie's Domain or the
--             browser keeps the original around).
function AuthCookies.clear(self)
    ngx.header["Set-Cookie"] = format_cookie(self, "", 0)
end

--- Read the refresh-token cookie from the incoming request.
-- @param self table Lapis request context (for ``self.req.headers``)
-- @return string|nil The cookie value, or nil if absent
function AuthCookies.read(self)
    -- Lapis populates self.cookies from the Cookie header. Try that
    -- first since it's the documented API.
    if self and self.cookies and self.cookies[COOKIE_NAME] then
        return self.cookies[COOKIE_NAME]
    end

    -- Fallback: parse the Cookie header by hand. Handles cases where
    -- self.cookies isn't populated yet (some lapis middleware orders)
    -- and keeps this helper usable from contexts that have only the
    -- raw request.
    local cookie_hdr = nil
    if self and self.req and self.req.headers then
        cookie_hdr = self.req.headers["cookie"] or self.req.headers["Cookie"]
    end
    if not cookie_hdr then return nil end

    for kv in cookie_hdr:gmatch("([^;]+)") do
        local k, v = kv:match("^%s*([^=]+)%s*=%s*(.*)%s*$")
        if k == COOKIE_NAME then
            return v
        end
    end
    return nil
end

return AuthCookies
