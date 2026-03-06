--[[
    Rate Limiting Middleware

    Uses OpenResty's ngx.shared.DICT for distributed counters across workers.
    Implements a sliding window counter per IP + route.

    Shared dicts (declared in nginx.conf):
      - rate_limit_store: main counter storage
      - rate_limit_locks: lock storage for atomic operations

    Returns standard rate limit headers:
      X-RateLimit-Limit     — max requests per window
      X-RateLimit-Remaining — requests left in current window
      X-RateLimit-Reset     — unix timestamp when window resets
      Retry-After           — seconds to wait (only on 429)
]]

local RateLimit = {}

local DICT_NAME = "rate_limit_store"

--- Get client IP, respecting X-Forwarded-For / X-Real-IP behind reverse proxy
-- @return string Client IP address
function RateLimit.getClientIP()
    -- X-Forwarded-For: client, proxy1, proxy2
    local xff = ngx.var.http_x_forwarded_for
    if xff then
        local ip = xff:match("^([^,]+)")
        if ip then return ip:match("^%s*(.-)%s*$") end
    end
    local real_ip = ngx.var.http_x_real_ip
    if real_ip then return real_ip end
    return ngx.var.remote_addr
end

--- Check rate limit for a given key
-- @param key string Unique key (typically "prefix:ip")
-- @param rate number Max requests per window
-- @param window number Window duration in seconds
-- @return boolean allowed
-- @return number remaining requests
-- @return number retry_after seconds (0 if allowed)
function RateLimit.check(key, rate, window)
    local dict = ngx.shared[DICT_NAME]
    if not dict then
        ngx.log(ngx.WARN, "rate-limit: shared dict '", DICT_NAME, "' not available, allowing request")
        return true, rate, 0
    end

    -- incr(key, value, init, init_ttl)
    -- Atomically increments. If key doesn't exist, initializes to init with init_ttl expiry.
    local current, err = dict:incr(key, 1, 0, window)
    if not current then
        ngx.log(ngx.ERR, "rate-limit: incr failed for key=", key, " err=", err)
        return true, rate, 0 -- fail open
    end

    if current > rate then
        local ttl = dict:ttl(key)
        local retry = math.ceil(ttl or window)
        return false, 0, retry
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
-- @param config table { rate: number, window: number, prefix: string }
-- @param handler function(self) The Lapis route handler
-- @return function Wrapped handler
function RateLimit.wrap(config, handler)
    local rate = config.rate or 60
    local window = config.window or 60
    local prefix = config.prefix or "default"

    return function(self)
        local ip = RateLimit.getClientIP()
        local key = prefix .. ":" .. ip

        local allowed, remaining, retry_after = RateLimit.check(key, rate, window)
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

    local allowed, remaining, retry_after = RateLimit.check(key, rate, window)
    set_headers(rate, remaining, retry_after)

    if not allowed then
        self:write(too_many_requests(retry_after))
        return false
    end

    return true
end

return RateLimit
