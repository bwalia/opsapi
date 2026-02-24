local CorsMiddleware = {}

-- Build domain patterns from CORS_ALLOWED_DOMAINS env variable
-- Format: comma-separated domain names, e.g. "diytaxreturn.co.uk,kisaan.com,opsapi.com"
local function buildDomainPatterns()
    local patterns = {}
    local domains_env = os.getenv("CORS_ALLOWED_DOMAINS") or ""

    for domain in domains_env:gmatch("[^,]+") do
        domain = domain:match("^%s*(.-)%s*$") -- trim whitespace
        if domain ~= "" then
            -- Escape dots for Lua pattern matching
            local escaped = domain:gsub("%.", "%%.")
            -- Allow the domain itself and all subdomains, with or without port
            table.insert(patterns, "^https?://" .. escaped .. "$")
            table.insert(patterns, "^https?://.*%." .. escaped .. "$")
            table.insert(patterns, "^https?://" .. escaped .. ":%d+$")
            table.insert(patterns, "^https?://.*%." .. escaped .. ":%d+$")
        end
    end

    return patterns
end

-- Professional CORS configuration for development and production
local CORS_CONFIG = {
    -- Development origins
    allowed_origins = {
        "http://127.0.0.1:3000",
        "http://127.0.0.1:3001",
        "http://127.0.0.1:3033",
        "http://127.0.0.1:3847",
        "http://127.0.0.1:4000",
        "http://127.0.0.1:8039",
        "http://127.0.0.1:3000",
        "http://127.0.0.1:3001",
        "http://127.0.0.1:3033",
        "http://127.0.0.1:3847",
        "http://127.0.0.1:4000",
        "http://127.0.0.1:8039",
        -- Workstation development servers
        "http://pop0.workstation.co.uk:8039",
        "http://pop0.workstation.co.uk:3000",
        "http://pop0.workstation.co.uk:3001"
    },
    -- Production domain patterns loaded from CORS_ALLOWED_DOMAINS env variable
    domain_patterns = buildDomainPatterns(),
    -- CORS headers - include all custom headers used by the frontend
    headers = {
        methods = "GET, POST, PUT, DELETE, OPTIONS, PATCH",
        headers = "Content-Type, Authorization, Accept, Origin, X-Requested-With, X-User-Email, X-Public-Browse, X-User-Id, X-Business-Id, X-Namespace-Id, X-Namespace-Slug, X-Vault-Key",
        max_age = "86400",
        credentials = "true"
    }
}

-- Check if origin is allowed
local function isOriginAllowed(origin)
    if not origin then
        -- Allow requests without origin (like Electron apps, curl, Postman, etc.)
        return true, "*"
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

    return false, "" -- empty value; browser will reject the cross-origin request
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
