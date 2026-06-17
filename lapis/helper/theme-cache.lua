--[[
    Theme Cache
    ===========

    Thin Redis cache-aside wrapper for rendered theme CSS. Keys are scoped
    by (namespace_id, project_code, version_epoch). Since every theme
    update bumps theme_tokens.updated_at via trigger, the version epoch
    naturally invalidates stale entries.

    Missing/unreachable Redis degrades to direct render — never throws.
    REDIS_ENABLED env var can disable the cache entirely (useful in tests
    and local dev).
]]

local ThemeCache = {}

local TTL_SECONDS     = 24 * 60 * 60   -- 24h — bounded by browser/CDN headers
local CONNECT_TIMEOUT = 500             -- ms
local READ_TIMEOUT    = 500             -- ms

local function redis_enabled()
    local val = os.getenv("REDIS_ENABLED")
    if val == nil or val == "" then return true end
    val = val:lower()
    return val ~= "false" and val ~= "0" and val ~= "no"
end

local function redis_config()
    return {
        host     = os.getenv("REDIS_HOST") or "127.0.0.1",
        port     = tonumber(os.getenv("REDIS_PORT")) or 6379,
        password = os.getenv("REDIS_PASSWORD"),
        db       = tonumber(os.getenv("REDIS_DB")) or 0,
    }
end

-- Acquire a connected Redis client; returns nil + reason on any failure.
local function connect()
    if not redis_enabled() then return nil, "redis disabled" end

    local ok, redis_mod = pcall(require, "resty.redis")
    if not ok then return nil, "resty.redis unavailable" end
    if not ngx or not ngx.socket then return nil, "nginx socket api unavailable" end

    local red = redis_mod:new()
    red:set_timeouts(CONNECT_TIMEOUT, READ_TIMEOUT, READ_TIMEOUT)

    local cfg = redis_config()
    local ok_conn, err = red:connect(cfg.host, cfg.port)
    if not ok_conn then return nil, "connect: " .. tostring(err) end

    if cfg.password and cfg.password ~= "" then
        local ok_auth, auth_err = red:auth(cfg.password)
        if not ok_auth then return nil, "auth: " .. tostring(auth_err) end
    end

    if cfg.db and cfg.db > 0 then
        local ok_sel, sel_err = red:select(cfg.db)
        if not ok_sel then return nil, "select: " .. tostring(sel_err) end
    end

    return red
end

-- Return connection to the pool (or close if pool unavailable).
local function release(red)
    if not red then return end
    local ok_pool = pcall(function() red:set_keepalive(10000, 50) end)
    if not ok_pool then pcall(function() red:close() end) end
end

local function css_key(namespace_id, project_code, version)
    return string.format("theme:css:%s:%s:%s",
        tostring(namespace_id or "default"),
        tostring(project_code or "default"),
        tostring(version or "0"))
end

--- Read rendered CSS for (namespace, project_code, version). Returns nil on miss.
function ThemeCache.getCss(namespace_id, project_code, version)
    local red, err = connect()
    if not red then return nil end

    local key = css_key(namespace_id, project_code, version)
    local res, get_err = red:get(key)
    release(red)

    if not res or res == ngx.null or res == "" then return nil end
    return res
end

--- Store rendered CSS with standard TTL.
function ThemeCache.setCss(namespace_id, project_code, version, css)
    if not css or css == "" then return end
    local red = connect()
    if not red then return end

    local key = css_key(namespace_id, project_code, version)
    red:set(key, css)
    red:expire(key, TTL_SECONDS)
    release(red)
end

--- Invalidate all cached CSS entries for (namespace, project_code). Called
-- on any theme update/activate/revert. Uses SCAN so we never block Redis.
function ThemeCache.invalidate(namespace_id, project_code)
    local red = connect()
    if not red then return end

    local pattern = string.format("theme:css:%s:%s:*",
        tostring(namespace_id or "default"),
        tostring(project_code or "default"))

    local cursor = "0"
    repeat
        local res, err = red:scan(cursor, "MATCH", pattern, "COUNT", 100)
        if not res or res == ngx.null then break end
        cursor = res[1]
        local keys = res[2]
        if keys and #keys > 0 then
            red:del(unpack(keys))
        end
    until cursor == "0"

    release(red)
end

return ThemeCache
