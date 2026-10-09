--[[
    Billing & Entitlements — protections for the public endpoints
    (docs/BILLING_ENTITLEMENTS.md §9): CORS and redirect allow-lists from the
    app's settings, rate limits and bad-key lockout, idempotency keys.

    Counters live in Redis (atomic INCR + EXPIRE, shared by every pod) and fall
    back to this pod's shared memory when Redis is off or unreachable. No IP
    address is stored anywhere else: counters expire with their window.
]]

local cjson = require("cjson")
local db = require("lapis.db")
local RedisClient = require("helper.redis-client")
local RateLimit = require("middleware.rate-limit")
local Settings = require("lib.billing-settings")

local Guard = {}

local function fail(status, code, message, extra)
    local body = { success = false, code = code, error = message }
    for k, v in pairs(extra or {}) do body[k] = v end
    return { status = status, json = body }
end
Guard.fail = fail

-- ---------------------------------------------------------------------------
-- Counters
-- ---------------------------------------------------------------------------

--- Count one hit on `key`: Redis (shared by every pod), else this pod's memory.
-- @return count, seconds left in the window
function Guard.incr(key, window)
    local n, ttl = RateLimit.incr("billing:" .. key, window)
    return n or 1, ttl or window
end

local function get(key)
    local red = RedisClient.connect()
    if red then
        local v = red:get("billing:" .. key)
        RedisClient.release(red)
        if v ~= nil then return v ~= ngx.null and v or nil end
    end
    local dict = ngx.shared.rate_limit_store
    return dict and dict:get("billing:" .. key)
end

local function set(key, value, ttl)
    local red = RedisClient.connect()
    if red then
        red:set("billing:" .. key, value, "EX", ttl)
        RedisClient.release(red)
        return
    end
    local dict = ngx.shared.rate_limit_store
    if dict then dict:set("billing:" .. key, value, ttl) end
end

function Guard.ip()
    return RateLimit.getClientIP()
end

--- Apply rate limits: checks = { { name, id, limit, window_seconds }, ... }.
-- @return nil when allowed, else a 429 response
function Guard.limit(app, checks)
    for _, c in ipairs(checks) do
        local n, ttl = Guard.incr(("rl:%s:%s:%s"):format(app.id, c[1], ngx.md5(tostring(c[2]))), c[4])
        if n > c[3] then
            ngx.header["Retry-After"] = tostring(ttl or c[4])
            return fail(429, "rate_limited", "Too many requests, try again later", { retry_after = ttl or c[4] })
        end
    end
    return nil
end

--- The app's rate-limit settings.
function Guard.rates(app)
    return Settings.resolve(app).rate_limits
end

-- ---------------------------------------------------------------------------
-- Lockout (bad licence keys)
-- ---------------------------------------------------------------------------

local function lock_key(app, ip) return ("lock:%s:%s"):format(app.id, ngx.md5(ip)) end

function Guard.lockedOut(app, ip)
    if get(lock_key(app, ip)) then
        local lock = Settings.resolve(app).lockout
        ngx.header["Retry-After"] = tostring(lock.lock_minutes * 60)
        return fail(429, "locked_out", "Too many invalid licence keys from this address; try again later")
    end
    return nil
end

--- Count a bad key; lock the address out when it reaches the limit.
function Guard.badKey(app, ip)
    local lock = Settings.resolve(app).lockout
    local n = Guard.incr(("fail:%s:%s"):format(app.id, ngx.md5(ip)), lock.window_minutes * 60)
    if n >= lock.failures then set(lock_key(app, ip), "1", lock.lock_minutes * 60) end
end

-- ---------------------------------------------------------------------------
-- CORS and redirects
-- ---------------------------------------------------------------------------

local function hosted_origin()
    local base = os.getenv("BILLING_HOSTED_BASE_URL")
    return base and base:match("^(https?://[^/]+)")
end

--- Browser requests: allowed only from the app's allowed_origins (or the
-- hosted pages). Native apps send no Origin and are unaffected.
-- @return nil when allowed, else a 403 response
function Guard.cors(self, app)
    local origin = self.req.headers["origin"]
    if not origin or origin == "" then return nil end
    local allowed = origin == hosted_origin()
    if not allowed then
        for _, o in ipairs(Settings.resolve(app).allowed_origins or {}) do
            if o == origin then allowed = true break end
        end
    end
    if allowed then
        ngx.header["Access-Control-Allow-Origin"] = origin
        ngx.header["Access-Control-Allow-Credentials"] = nil
        ngx.header["Vary"] = "Origin"
        return nil
    end
    ngx.header["Access-Control-Allow-Origin"] = nil
    ngx.header["Access-Control-Allow-Credentials"] = nil
    if self.req.method ~= "GET" then
        return fail(403, "origin_not_allowed", "This origin may not call this app's endpoints")
    end
    return nil
end

-- scheme, host, port (default by scheme) and path of an http(s) URL; nil for
-- anything else (userinfo, backslashes, encoded or literal dot segments).
local function parse_url(u)
    if type(u) ~= "string" or u == "" or #u > 1000 or u:find("[%s\\]") then return nil end
    local scheme, authority, rest = u:match("^(https?)://([^/?#]+)(.*)$")
    if not scheme or authority:find("@", 1, true) then return nil end
    local host, port = authority:match("^([^:]+):(%d+)$")
    if not host then host, port = authority, (scheme == "https" and "443" or "80") end
    local path = rest:match("^([^?#]*)")
    if path == "" then path = "/" end
    local lower = path:lower()
    if lower:find("%2e", 1, true) or lower:find("%2f", 1, true) or lower:find("%5c", 1, true)
        or ("/" .. path .. "/"):find("/%.%.?/") then
        return nil
    end
    return { scheme = scheme:lower(), host = host:lower(), port = port, path = path }
end

--- A return/success/cancel URL must be on one of allowed_redirect_urls (or the
-- hosted pages' base URL): same scheme, host and port, and a path at or below the
-- allowed one, on a "/" boundary (/account allows /account and /account/x, not /accounts).
function Guard.redirectAllowed(app, url)
    local u = parse_url(url)
    if not u then return false end
    local prefixes = { os.getenv("BILLING_HOSTED_BASE_URL") }
    for _, p in ipairs(Settings.resolve(app).allowed_redirect_urls or {}) do prefixes[#prefixes + 1] = p end
    for _, p in ipairs(prefixes) do
        local a = parse_url(p)
        if a and a.scheme == u.scheme and a.host == u.host and a.port == u.port then
            local base = a.path:gsub("/+$", "")
            if base == "" or u.path == base or u.path:sub(1, #base + 1) == base .. "/" then return true end
        end
    end
    return false
end

-- ---------------------------------------------------------------------------
-- Idempotency keys
-- ---------------------------------------------------------------------------

-- What is kept for replays never holds a raw licence key (docs §10): a replay
-- gets the same answer without it (key_redacted = true); a lost key is reissued.
local function redact(json)
    local data = type(json) == "table" and json.data
    if type(data) ~= "table" or data.key == nil then return json end
    local copy, d = {}, {}
    for k, v in pairs(json) do copy[k] = v end
    for k, v in pairs(data) do d[k] = v end
    d.key, d.key_redacted = nil, true
    copy.data = d
    return copy
end
Guard._redact = redact

--- Run `fn` at most once per Idempotency-Key within 24 h. The same key with
-- the same body replays the stored response; a different body is a 409.
-- Without the header, `fn` simply runs (unless required).
function Guard.idempotent(self, scope, body, fn, required)
    local key = self.req.headers["idempotency-key"]
    if not key or key == "" then
        if required then return fail(400, "idempotency_key_required", "Send an Idempotency-Key header") end
        return fn()
    end
    if #key > 255 then return fail(400, "bad_idempotency_key", "Idempotency-Key is at most 255 characters") end
    -- The caller is part of the request: another session or user reusing the key gets a 409, not this answer.
    local who = (self.req.headers["x-billing-session"] or "") .. "|"
        .. tostring(self.current_user and (self.current_user.key_uuid or self.current_user.uuid) or "")
    local hash = ngx.md5(cjson.encode(body or {}) .. "|" .. ngx.md5(who))
    local inserted = db.query([[
        INSERT INTO billing_idempotency (scope, idem_key, request_hash, expires_at)
        VALUES (?, ?, ?, NOW() + interval '24 hours')
        ON CONFLICT (scope, idem_key) DO NOTHING RETURNING id
    ]], scope, key, hash)[1]
    if not inserted then
        local row = db.query([[SELECT request_hash, status, response FROM billing_idempotency
            WHERE scope = ? AND idem_key = ? AND expires_at > NOW()]], scope, key)[1]
        if not row then
            -- Expired: start over.
            db.query("DELETE FROM billing_idempotency WHERE scope = ? AND idem_key = ?", scope, key)
            return Guard.idempotent(self, scope, body, fn, required)
        end
        if row.request_hash ~= hash then
            return fail(409, "idempotency_mismatch", "This Idempotency-Key was used with a different request")
        end
        if row.status == nil or row.status == db.NULL then
            return fail(409, "in_progress", "A request with this Idempotency-Key is still running")
        end
        ngx.header["Idempotent-Replayed"] = "true"
        return { status = tonumber(row.status), json = cjson.decode(row.response) }
    end
    local ok, res = pcall(fn)
    if not ok or not res or (res.status or 200) >= 500 then
        -- Not stored: the client may retry with the same key.
        db.query("DELETE FROM billing_idempotency WHERE id = ?", inserted.id)
        if not ok then error(res) end
        return res
    end
    db.query("UPDATE billing_idempotency SET status = ?, response = ? WHERE id = ?",
        res.status or 200, cjson.encode(redact(res.json or {})), inserted.id)
    return res
end

return Guard
