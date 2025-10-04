local CorsMiddleware = {}

-- Professional CORS configuration for development and production
local CORS_CONFIG = {
    -- Development origins
    allowed_origins = {
        "http://localhost:3000",
        "http://localhost:3001",
        "http://localhost:3033",
        "http://localhost:4000",
        "http://127.0.0.1:3000",
        "http://127.0.0.1:3001",
        "http://127.0.0.1:3033",
        "http://127.0.0.1:4000"
    },
    -- Production domain patterns
    domain_patterns = {
        "^https?://googleapis%.com$",
        "^https?://.*%.googleapis%.com$"
    },
    -- CORS headers
    headers = {
        methods = "GET, POST, PUT, DELETE, OPTIONS, PATCH",
        headers = "Content-Type, Authorization, X-User-Email, X-Public-Browse, X-User-Id, X-Requested-With",
        max_age = "86400",
        credentials = "true"
    }
}

-- Check if origin is allowed
local function isOriginAllowed(origin)
    if not origin then
        return false, "http://localhost:3000" -- default fallback
    end

    -- Check exact matches for development origins
    for _, allowed in ipairs(CORS_CONFIG.allowed_origins) do
        if origin == allowed then
            return true, origin
        end
    end

    -- Check domain patterns for production
    for _, pattern in ipairs(CORS_CONFIG.domain_patterns) do
        if origin:match(pattern) then
            return true, origin
        end
    end

    return false, "http://localhost:3000" -- fallback for unmatched origins
end

function CorsMiddleware.enable(app)
    ngx.log(ngx.INFO, "CORS middleware enabled")
    app:before_filter(function(self)
        local origin = self.req.headers["origin"] or self.req.headers["Origin"]
        local is_allowed, allowed_origin = isOriginAllowed(origin)

        -- Set CORS headers for all requests
        self.res.headers["Access-Control-Allow-Origin"] = allowed_origin or "localhost:3133,http://localhost:4010,http://localhost:3000,http://localhost:8080"
        self.res.headers["Access-Control-Allow-Credentials"] = "true"
        self.res.headers["Access-Control-Allow-Methods"] = "GET, POST, PUT, DELETE, OPTIONS"
        self.res.headers["Access-Control-Allow-Headers"] = "Content-Type, Authorization, X-User-Email, X-Public-Browse"

        -- Handle preflight OPTIONS requests
        if self.req.method == "OPTIONS" then
            return { status = 200 }
        end
    end)
end

return CorsMiddleware
-- CORS middleware for Lapis with professional configuration