local CorsMiddleware = {}

-- Professional CORS configuration for development and production
local CORS_CONFIG = {
    -- Development origins
    allowed_origins = {
        "http://localhost:3000",
        "http://localhost:3001",
        "http://localhost:3033",
        "http://localhost:4000",
        "http://localhost:8039",
        "http://127.0.0.1:3000",
        "http://127.0.0.1:3001",
        "http://127.0.0.1:3033",
        "http://127.0.0.1:4000",
        "http://127.0.0.1:8039",
        -- Workstation development servers
        "http://pop0.workstation.co.uk:8039",
        "http://pop0.workstation.co.uk:3000",
        "http://pop0.workstation.co.uk:3001"
    },
    -- Production domain patterns (add your production domains here)
    domain_patterns = {
        "^https?://kisaan%.com$",
        "^https?://.*%.kisaan%.com$",
        "^https?://wslcrm%.com$",
        "^https?://.*%.wslcrm%.com$",
        "^https?://opsapi%.com$",
        "^https?://.*%.opsapi%.com$",
        "^https?://workstation%.co%.uk$",
        "^https?://.*%.workstation%.co%.uk$",
        "^https?://.*%.workstation%.co%.uk:%d+$"  -- Allow any port on workstation.co.uk subdomains
    },
    -- CORS headers - include all custom headers used by the frontend
    headers = {
        methods = "GET, POST, PUT, DELETE, OPTIONS, PATCH",
        headers = "Content-Type, Authorization, Accept, Origin, X-Requested-With, X-User-Email, X-Public-Browse, X-User-Id, X-Namespace-Id, X-Namespace-Slug",
        max_age = "86400",
        credentials = "true"
    }
}

-- Check if origin is allowed
local function isOriginAllowed(origin)
    if not origin then
        return false, "http://localhost:5173" -- default fallback
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

    return false, "http://localhost:5173" -- fallback for unmatched origins
end

function CorsMiddleware.enable(app)
    app:before_filter(function(self)
        local origin = self.req.headers["origin"] or self.req.headers["Origin"]
        local is_allowed, allowed_origin = isOriginAllowed(origin)

        -- Set CORS headers for all requests
        self.res.headers["Access-Control-Allow-Origin"] = allowed_origin
        self.res.headers["Access-Control-Allow-Credentials"] = CORS_CONFIG.headers.credentials
        self.res.headers["Access-Control-Allow-Methods"] = CORS_CONFIG.headers.methods
        self.res.headers["Access-Control-Allow-Headers"] = CORS_CONFIG.headers.headers
        self.res.headers["Access-Control-Max-Age"] = CORS_CONFIG.headers.max_age

        -- Handle preflight OPTIONS requests
        if self.req.method == "OPTIONS" then
            ngx.exit(204)
        end
    end)
end

return CorsMiddleware
-- CORS middleware for Lapis with professional configuration