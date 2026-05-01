--[[
    Global Rate Limiting Middleware (OpsAPI)

    Mirrors the FastAPI FASTAPI_RATE_LIMIT_DEFAULT pattern. The global limit is
    controlled via the OPSAPI_RATE_LIMIT_DEFAULT env var (default: "10000/minute").
    Accepts slowapi-style strings: "N/second", "N/minute", "N/hour", "N/day".

    Per-route limits declared via RateLimit.wrap / RateLimit.checkBefore still apply
    on top of this default.

    Also logs the X-Proxy-Pop-Code header so we can correlate requests to the edge
    location they entered the network at.
]]

local RateLimit = require("middleware.rate-limit")

local GlobalRateLimit = {}

--- Parse a "N/unit" string into { rate: number, window: number }
-- @param s string e.g. "10000/minute", "100/second"
-- @return table { rate, window } or nil on parse error
local function parse_spec(s)
    if type(s) ~= "string" then return nil end
    local n, unit = s:match("^%s*(%d+)%s*/%s*(%a+)%s*$")
    if not n or not unit then return nil end
    local window_map = {
        second = 1, seconds = 1,
        minute = 60, minutes = 60,
        hour = 3600, hours = 3600,
        day = 86400, days = 86400,
    }
    local window = window_map[unit:lower()]
    if not window then return nil end
    return { rate = tonumber(n), window = window }
end

--- Resolve the global rate limit from env var, with a safe default.
local function resolve_limit()
    local spec = os.getenv("OPSAPI_RATE_LIMIT_DEFAULT") or "10000/minute"
    local parsed = parse_spec(spec)
    if not parsed then
        ngx.log(ngx.WARN,
            "global-rate-limit: invalid OPSAPI_RATE_LIMIT_DEFAULT='", spec,
            "' — falling back to 10000/minute")
        return { rate = 10000, window = 60 }
    end
    return parsed
end

-- Cached on first request; env vars don't change during worker lifetime.
local cached_limit

--- Install a before_filter on the Lapis app that enforces the global limit
-- and logs X-Proxy-Pop-Code on every request.
function GlobalRateLimit.enable(app)
    app:before_filter(function(self)
        -- Log proxy POP code if present (for edge-location correlation)
        local pop = ngx.var.http_x_proxy_pop_code
        if pop and pop ~= "" then
            ngx.log(ngx.INFO,
                "request.pop_code=", pop,
                " path=", ngx.var.uri,
                " ip=", RateLimit.getClientIP())
        end

        -- Resolve limit once per worker
        if not cached_limit then
            cached_limit = resolve_limit()
        end

        -- Apply the global default (per-route limits still check independently)
        if not RateLimit.checkBefore(self, {
            rate = cached_limit.rate,
            window = cached_limit.window,
            prefix = "global",
        }) then
            -- checkBefore already wrote the 429; abort further filters/handlers
            return false
        end
    end)
end

return GlobalRateLimit
