local CorsMiddleware = {}

-- Tier 1: Check if origin is a localhost/loopback address (any port)
-- Covers: http(s)://localhost, http(s)://localhost:PORT,
--         http(s)://127.0.0.1, http(s)://127.0.0.1:PORT,
--         http(s)://[::1], http(s)://[::1]:PORT
-- Safe in production: the Origin header reflects the browser's page origin,
-- not the server. A remote attacker's browser sends their actual origin, not localhost.
local function isLocalhostOrigin(origin)
    if not origin then
        return false
    end
    if origin:match("^https?://localhost$") or origin:match("^https?://localhost:%d+$") then
        return true
    end
    if origin:match("^https?://127%.0%.0%.1$") or origin:match("^https?://127%.0%.0%.1:%d+$") then
        return true
    end
    if origin:match("^https?://%[::1%]$") or origin:match("^https?://%[::1%]:%d+$") then
        return true
    end
    return false
end

-- Tier 2: Build domain patterns from CORS_ALLOWED_DOMAINS env variable
-- Format: comma-separated domain names, e.g. "diytaxreturn.co.uk,kisaan.com,opsapi.com"
-- Each domain generates patterns for: the domain itself, all subdomains, with or without port
local function buildDomainPatterns()
    local patterns = {}
    local domains_env = os.getenv("CORS_ALLOWED_DOMAINS") or ""

    for domain in domains_env:gmatch("[^,]+") do
        domain = domain:match("^%s*(.-)%s*$") -- trim whitespace
        if domain ~= "" then
            local escaped = domain:gsub("%.", "%%."):gsub("%-", "%%-")
            table.insert(patterns, "^https?://" .. escaped .. "$")
            table.insert(patterns, "^https?://.*%." .. escaped .. "$")
            table.insert(patterns, "^https?://" .. escaped .. ":%d+$")
            table.insert(patterns, "^https?://.*%." .. escaped .. ":%d+$")
        end
    end

    return patterns
end

-- Tier 3: Build explicit origin list from CORS_ALLOWED_ORIGINS env variable
-- Format: comma-separated full origin URLs,
-- e.g. "http://pop0.workstation.co.uk:8039,https://app.example.com"
local function buildAllowedOrigins()
    local origins = {}
    local origins_env = os.getenv("CORS_ALLOWED_ORIGINS") or ""

    for origin in origins_env:gmatch("[^,]+") do
        origin = origin:match("^%s*(.-)%s*$") -- trim whitespace
        if origin ~= "" then
            origins[origin] = true -- hash table for O(1) lookup
        end
    end

    return origins
end

-- Build configuration once at module load time
local CORS_CONFIG = {
    domain_patterns = buildDomainPatterns(),
    allowed_origins = buildAllowedOrigins(),
    headers = {
        methods = "GET, POST, PUT, DELETE, OPTIONS, PATCH",
        headers = "Content-Type, Authorization, Accept, Origin, X-Requested-With, X-User-Email, X-Public-Browse, X-User-Id, X-Business-Id, X-Namespace-Id, X-Namespace-Slug, X-Vault-Key",
        max_age = "86400",
        credentials = "true"
    }
}

-- Check if origin is allowed using the three-tier system
local function isOriginAllowed(origin)
    if not origin then
        -- No Origin header: non-browser clients (curl, Postman, server-to-server)
        -- Return nil to signal "no CORS headers needed" (not a CORS request)
        return true, nil
    end

    -- Tier 1: Always allow localhost/loopback on any port
    if isLocalhostOrigin(origin) then
        return true, origin
    end

    -- Tier 2: Check domain patterns from CORS_ALLOWED_DOMAINS
    for _, pattern in ipairs(CORS_CONFIG.domain_patterns) do
        if origin:match(pattern) then
            return true, origin
        end
    end

    -- Tier 3: Check explicit origins from CORS_ALLOWED_ORIGINS
    if CORS_CONFIG.allowed_origins[origin] then
        return true, origin
    end

    return false, nil
end

function CorsMiddleware.enable(app)
    app:before_filter(function(self)
        local origin = self.req.headers["origin"] or self.req.headers["Origin"]
        local allowed, allowed_origin = isOriginAllowed(origin)

        -- Always set Vary: Origin so CDNs/proxies don't serve cached CORS
        -- headers from one origin to a different origin
        self.res.headers["Vary"] = "Origin"

        if allowed and allowed_origin then
            -- Origin is allowed: set full CORS headers with the specific origin
            self.res.headers["Access-Control-Allow-Origin"] = allowed_origin
            self.res.headers["Access-Control-Allow-Credentials"] = CORS_CONFIG.headers.credentials
            self.res.headers["Access-Control-Allow-Methods"] = CORS_CONFIG.headers.methods
            self.res.headers["Access-Control-Allow-Headers"] = CORS_CONFIG.headers.headers
            self.res.headers["Access-Control-Max-Age"] = CORS_CONFIG.headers.max_age
        end
        -- If not allowed or no origin (non-browser client): no CORS headers set,
        -- browser will block the cross-origin request naturally

        -- Handle preflight OPTIONS requests
        if self.req.method == "OPTIONS" then
            ngx.exit(204)
        end
    end)
end

return CorsMiddleware
