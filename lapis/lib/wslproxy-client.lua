--[[
    WSL Proxy control-plane API client (per-namespace)
    ==================================================

    Thin client over the WSL Proxy admin API so opsapi can list/fetch the SHARED
    rules a domain attaches to (instead of minting one rule per domain).

    Auth is per-namespace: each namespace stores its own connection (api_url +
    email + AES-encrypted password) via WslproxyConnectionQueries. This module
    decrypts server-side, logs in (POST /api/user/login -> body.data.accessToken),
    caches the bearer token per namespace, and re-logs-in once on 401.

    Endpoints used:
      POST /api/user/login   { email, password }        -> { data: { accessToken } }
      GET  /api/rules                                    -> list (or { data: [...] })
      GET  /api/rules/{id}                               -> one  (or { data: {...} })

    Every function returns (result, err) — it never throws across the route
    boundary. The WSL Proxy admin token expires ~1h with no refresh, so a cached
    token is used until it 401s, then we re-login exactly once.
]]

local cjson = require("cjson")
local WslproxyConnectionQueries = require("queries.WslproxyConnectionQueries")

local WslproxyClient = {}

-- Per-namespace token cache. ngx.shared would share across workers, but a plain
-- module table is enough here (a re-login per worker is cheap and self-healing).
-- ponytail: per-worker cache; move to ngx.shared.wslproxy_tokens if login QPS matters.
local token_cache = {}
local TOKEN_TTL = 45 * 60 -- seconds, comfortably under HMRC-style ~1h expiry

local function now()
    return (ngx and ngx.now and ngx.now()) or os.time()
end

local function trim_url(u)
    return (tostring(u or ""):gsub("%s+$", ""):gsub("/+$", ""))
end

-- Verify TLS for https endpoints (production); http (internal) has no TLS to
-- verify. Requires lua_ssl_trusted_certificate in nginx.conf for https verify.
local function ssl_verify_for(url)
    return url:match("^https://") ~= nil
end

local function http_request(url, opts)
    local ok, http = pcall(require, "resty.http")
    if not ok then return nil, "resty.http not available" end
    local httpc = http.new()
    httpc:set_timeout(opts.timeout or 15000)
    local res, rerr = httpc:request_uri(url, {
        method = opts.method or "GET",
        headers = opts.headers,
        body = opts.body,
        ssl_verify = ssl_verify_for(url),
    })
    if not res then return nil, "WSL Proxy not reachable: " .. tostring(rerr) end
    local decoded
    if res.body and res.body ~= "" then
        local dok, d = pcall(cjson.decode, res.body)
        if dok then decoded = d end
    end
    return { status = res.status, body = decoded, raw = res.body }, nil
end

-- Log in and return a fresh token (bypasses the cache).
local function login(conn)
    local url = trim_url(conn.api_url) .. "/api/user/login"
    local res, err = http_request(url, {
        method = "POST",
        headers = { ["Content-Type"] = "application/json", ["Accept"] = "application/json" },
        body = cjson.encode({ email = conn.email, password = conn.password }),
    })
    if not res then return nil, err end
    if res.status == 401 or res.status == 403 then
        return nil, "WSL Proxy login rejected — check the email and password"
    end
    if res.status >= 400 then
        return nil, "WSL Proxy login failed (HTTP " .. tostring(res.status) .. ")"
    end
    local b = res.body or {}
    local token = (b.data and b.data.accessToken) or b.accessToken or b.token
    if not token or token == "" then
        return nil, "WSL Proxy login returned no token"
    end
    return token, nil
end

-- Validate ad-hoc credentials by attempting a login (used by /connect before
-- anything is persisted). @param conn { api_url, email, password }.
-- @return true, nil  OR  false, err
function WslproxyClient.verify(conn)
    if not conn or trim_url(conn.api_url) == "" then return false, "api_url is required" end
    local token, err = login(conn)
    if not token then return false, err end
    return true, nil
end

-- A namespace-bound client: { get(path), list_rules(search), get_rule(id) }.
-- Returns nil, err if the namespace has no stored connection.
function WslproxyClient.for_namespace(namespace_id)
    local conn, cerr = WslproxyConnectionQueries.getDecrypted(namespace_id)
    if not conn then return nil, cerr end
    local base = trim_url(conn.api_url)

    local function ensure_token(force)
        local cached = token_cache[namespace_id]
        if not force and cached and cached.token and cached.exp > now() then
            return cached.token, nil
        end
        local token, err = login(conn)
        if not token then
            token_cache[namespace_id] = nil
            return nil, err
        end
        token_cache[namespace_id] = { token = token, exp = now() + TOKEN_TTL }
        return token, nil
    end

    -- GET {path}, re-logging in once on 401. Returns (decoded_body, raw, err).
    local function get(path)
        local token, terr = ensure_token(false)
        if not token then return nil, nil, terr end
        local function call(tok)
            return http_request(base .. path, {
                method = "GET",
                headers = { ["Authorization"] = "Bearer " .. tok, ["Accept"] = "application/json" },
            })
        end
        local res, err = call(token)
        if not res then return nil, nil, err end
        if res.status == 401 then -- token likely expired: re-login once and retry
            token, terr = ensure_token(true)
            if not token then return nil, nil, terr end
            res, err = call(token)
            if not res then return nil, nil, err end
        end
        if res.status == 404 then return nil, nil, "not_found" end
        if res.status >= 400 then
            return nil, nil, "WSL Proxy API error (HTTP " .. tostring(res.status) .. ")"
        end
        return res.body, res.raw, nil
    end

    -- Normalise the list response to a plain array of rule objects, optionally
    -- filtered by a name/id search and by environment (rule.profile_id).
    local function list_rules(search, environment)
        local body, _, err = get("/api/rules")
        if err then return nil, err end
        local items = body
        if type(body) == "table" and body.data ~= nil then items = body.data end
        if type(items) ~= "table" then items = {} end
        local q = (search and search ~= "") and tostring(search):lower() or nil
        local env = (environment and environment ~= "") and tostring(environment) or nil
        if not q and not env then return items, nil end
        local out = {}
        for _, r in ipairs(items) do
            local ok_env = (not env) or (tostring(r.profile_id or "") == env)
            local ok_q = true
            if q then
                local hay = ((r.name or "") .. " " .. (r.id or "")):lower()
                ok_q = hay:find(q, 1, true) ~= nil
            end
            if ok_env and ok_q then table.insert(out, r) end
        end
        return out, nil
    end

    -- Fetch one rule. Returns (rule_table, raw_json_string, err). raw preserves
    -- the exact JSON shape for committing verbatim to the repo.
    local function get_rule(id)
        if not id or id == "" then return nil, nil, "rule id required" end
        local body, raw, err = get("/api/rules/" .. tostring(id))
        if err == "not_found" then return nil, nil, "rule not found in WSL Proxy: " .. tostring(id) end
        if err then return nil, nil, err end
        local rule = body
        if type(body) == "table" and body.data ~= nil then rule = body.data end
        -- Re-encode from the unwrapped object so the committed file is the rule
        -- itself, not the { data: ... } envelope.
        local out_raw = raw
        if type(body) == "table" and body.data ~= nil then
            out_raw = cjson.encode(rule)
        end
        return rule, out_raw, nil
    end

    return {
        namespace_id = namespace_id,
        api_url = base,
        get = get,
        list_rules = list_rules,
        get_rule = get_rule,
    }, nil
end

return WslproxyClient
