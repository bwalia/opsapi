--[[
    Rate Limiting Middleware

    Fixed-window counter per IP + route. Per-route limits count in Redis, so
    the limit holds across every pod; when Redis is off or unreachable they
    count in this pod's shared memory (rate_limit_store). The global limit
    (middleware/global-rate-limit.lua) runs on every request and stays in
    shared memory (local_only): a per-pod DDoS guard needs no network hop.

    Returns standard rate limit headers:
      X-RateLimit-Limit     — max requests per window
      X-RateLimit-Remaining — requests left in current window
      X-RateLimit-Reset     — unix timestamp when window resets
      Retry-After           — seconds to wait (only on 429)
]]

local RedisClient = require("helper.redis-client")

local RateLimit = {}

local DICT_NAME = "rate_limit_store"

-- INCR and set the expiry on the first hit, atomically. @return {count, ttl}
local INCR = "local n = redis.call('INCR', KEYS[1]) if n == 1 then redis.call('EXPIRE', KEYS[1], ARGV[1]) end "
    .. "return {n, redis.call('TTL', KEYS[1])}"

--- Count one hit on `key` in a `window`-second window: in Redis (one count for
-- every pod) unless `local_only`, else in this pod's shared memory.
-- @return count, seconds left in the window | nil when nothing can count
function RateLimit.incr(key, window, local_only)
    if not local_only then
        local red = RedisClient.connect()
        if red then
            local res = red:eval(INCR, 1, key, window)
            if type(res) == "table" then
                RedisClient.release(red)
                return tonumber(res[1]), tonumber(res[2])
            end
            red:close()
        end
    end
    local dict = ngx.shared[DICT_NAME]
    local n = dict and dict:incr(key, 1, 0, window)
    if not n then return nil end
    return n, dict:ttl(key)
end

--- The client's IP, as our own proxies saw it (helper/client-ip.lua: the
-- right-most X-Forwarded-For hop that isn't a trusted proxy, trusted =
-- internal ranges + OPSAPI_TRUSTED_PROXIES). The left-most entry is whatever
-- the client wrote, so it is never used.
-- @return string Client IP address
function RateLimit.getClientIP()
    return require("helper.client-ip").get()
end

--- Check rate limit for a given key
-- @param key string Unique key (typically "prefix:ip")
-- @param rate number Max requests per window
-- @param window number Window duration in seconds
-- @param local_only boolean count in this pod only (the global limit)
-- @return boolean allowed
-- @return number remaining requests
-- @return number retry_after seconds (0 if allowed)
function RateLimit.check(key, rate, window, local_only)
    local current, ttl = RateLimit.incr("rl:" .. key, window, local_only)
    if not current then
        return true, rate, 0 -- fail open: nothing to count with
    end
    if current > rate then
        return false, 0, math.ceil((ttl and ttl > 0) and ttl or window)
    end
    return true, rate - current, 0
end

--- Set rate limit response headers
-- @param rate number Max requests per window
-- @param remaining number Requests remaining
-- @param retry_after number Seconds until reset (0 if not rate limited)
local function set_headers(rate, remaining, retry_after)
    ngx.header["X-RateLimit-Limit"] = tostring(rate)
    ngx.header["X-RateLimit-Remaining"] = tostring(math.max(remaining, 0))
    if retry_after > 0 then
        ngx.header["Retry-After"] = tostring(retry_after)
        ngx.header["X-RateLimit-Reset"] = tostring(ngx.time() + retry_after)
    end
end

--- Build the 429 response
local function too_many_requests(retry_after)
    return {
        status = 429,
        json = {
            error = "Too many requests. Please try again later.",
            retry_after = retry_after
        }
    }
end

--- Wrap a Lapis route handler with rate limiting
-- Use with app:post, app:get, etc.
--
-- Example:
--   app:post("/auth/login", RateLimit.wrap({ rate = 10, window = 60, prefix = "login" }, function(self)
--       ...
--   end))
--
-- @param config table { rate: number, window: number, prefix: string, local_only: boolean }
-- @param handler function(self) The Lapis route handler
-- @return function Wrapped handler
function RateLimit.wrap(config, handler)
    local rate = config.rate or 60
    local window = config.window or 60
    local prefix = config.prefix or "default"

    return function(self)
        local ip = RateLimit.getClientIP()
        local key = prefix .. ":" .. ip

        local allowed, remaining, retry_after = RateLimit.check(key, rate, window, config.local_only)
        set_headers(rate, remaining, retry_after)

        if not allowed then
            return too_many_requests(retry_after)
        end

        return handler(self)
    end
end

--- Rate limit check for respond_to `before` filters
-- Call in a `before` function; writes 429 and returns false if exceeded.
--
-- Example:
--   before = function(self)
--       if not RateLimit.checkBefore(self, { rate = 30, window = 60, prefix = "api" }) then
--           return
--       end
--       -- ... rest of before logic
--   end
--
-- @param self table Lapis request object
-- @param config table { rate: number, window: number, prefix: string }
-- @return boolean true if allowed, false if rate limited (already wrote 429)
function RateLimit.checkBefore(self, config)
    local rate = config.rate or 60
    local window = config.window or 60
    local prefix = config.prefix or "default"

    local ip = RateLimit.getClientIP()
    local key = prefix .. ":" .. ip

    local allowed, remaining, retry_after = RateLimit.check(key, rate, window, config.local_only)
    set_headers(rate, remaining, retry_after)

    if not allowed then
        self:write(too_many_requests(retry_after))
        return false
    end

    return true
end

return RateLimit
