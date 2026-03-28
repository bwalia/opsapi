-- Professional Health Check System
-- Production-ready health checks for all critical services

local db = require("lapis.db")
local redis = require("resty.redis")
local http = require("resty.http")

local HealthCheck = {}

-- ── DNS resolution helper (mirrors minio.lua logic) ──────────────────────────
-- In K8s, resty.http can't resolve .svc.cluster.local hostnames via the nginx
-- resolver. This helper uses resty.dns.resolver to query CoreDNS directly,
-- then replaces the hostname in the URL with the resolved IP.
local _dns_cache = {}
local DNS_CACHE_TTL = 30

local function is_kubernetes()
    local f = io.open("/var/run/secrets/kubernetes.io/serviceaccount/token", "r")
    if f then f:close(); return true end
    return false
end

local function resolve_for_health_check(url)
    if not url or url == "" then return url end
    if not is_kubernetes() then return url end

    -- Extract hostname from URL: http://hostname:port/path
    local scheme, host, port, path = url:match("^(https?)://([^:/]+):?(%d*)(.*)")
    if not host then return url end
    if host:match("^%d+%.%d+%.%d+%.%d+$") then return url end -- already IP

    -- Check cache
    local cached = _dns_cache[host]
    if cached and cached.expires > ngx.now() then
        local resolved_url = scheme .. "://" .. cached.ip .. (port ~= "" and (":" .. port) or "") .. path
        return resolved_url
    end

    -- Get nameservers from /etc/resolv.conf (skip 127.x.x.x)
    local nameservers = {}
    local f = io.open("/etc/resolv.conf", "r")
    if f then
        for line in f:lines() do
            local ns = line:match("^nameserver%s+(%S+)")
            if ns and not ns:match("^127%.") then
                nameservers[#nameservers + 1] = ns
            end
        end
        f:close()
    end
    if #nameservers == 0 then return url end

    -- Resolve using resty.dns.resolver
    local ok_mod, dns = pcall(require, "resty.dns.resolver")
    if not ok_mod then return url end

    local r, err = dns:new({ nameservers = nameservers, retrans = 2, timeout = 2000 })
    if not r then return url end

    local answers, err = r:query(host, { qtype = r.TYPE_A })
    if not answers or answers.errcode then return url end

    for _, ans in ipairs(answers) do
        if ans.type == r.TYPE_A and ans.address then
            _dns_cache[host] = { ip = ans.address, expires = ngx.now() + DNS_CACHE_TTL }
            local resolved_url = scheme .. "://" .. ans.address .. (port ~= "" and (":" .. port) or "") .. path
            return resolved_url
        end
    end

    return url
end

-- Get database connection status
function HealthCheck.checkDatabase()
    local start_time = ngx.now()
    local status = {
        name = "database",
        status = "healthy",
        response_time_ms = 0,
        details = {}
    }

    -- Test database connection with a simple query
    local success, result = pcall(function()
        return db.query("SELECT 1 as test, NOW() as server_time")
    end)

    status.response_time_ms = math.floor((ngx.now() - start_time) * 1000)

    if not success then
        status.status = "unhealthy"
        status.error = "Database connection failed: " .. tostring(result)
        return status
    end

    if not result or #result == 0 then
        status.status = "unhealthy"
        status.error = "Database query returned no results"
        return status
    end

    -- Add database info
    status.details = {
        connected = true,
        server_time = result[1].server_time,
        test_query = "passed"
    }

    -- Get database version
    local ver_success, ver_result = pcall(function()
        return db.query("SELECT version() as version, current_database() as db_name")
    end)

    if ver_success and ver_result and ver_result[1] then
        status.details.version = ver_result[1].version
        status.details.database_name = ver_result[1].db_name
    end

    -- Get database statistics
    local stats_success, stats_result = pcall(function()
        local db_stats = db.query([[
            SELECT
                (SELECT COUNT(*) FROM users) as total_users,
                pg_database_size(current_database()) as database_size
        ]])
        return db_stats[1]
    end)

    if stats_success and stats_result then
        status.details.total_users = stats_result.total_users or 0
        status.details.database_size_bytes = stats_result.database_size or 0
        -- Human-readable size
        local size = tonumber(stats_result.database_size) or 0
        if size > 1073741824 then
            status.details.database_size = string.format("%.1f GB", size / 1073741824)
        elseif size > 1048576 then
            status.details.database_size = string.format("%.1f MB", size / 1048576)
        else
            status.details.database_size = string.format("%.1f KB", size / 1024)
        end
    end

    return status
end

-- Check Redis connection (only when REDIS_ENABLED=true)
function HealthCheck.checkRedis()
    local redis_enabled = os.getenv("REDIS_ENABLED")
    if redis_enabled ~= "true" and redis_enabled ~= "1" then
        return {
            name = "redis",
            status = "skipped",
            response_time_ms = 0,
            details = { enabled = false, message = "Redis is disabled (REDIS_ENABLED is not true)" }
        }
    end

    local start_time = ngx.now()
    local status = {
        name = "redis",
        status = "healthy",
        response_time_ms = 0,
        details = { enabled = true }
    }

    local success, result = pcall(function()
        local red = redis:new()
        red:set_timeout(1000) -- 1 second timeout

        local ok, err = red:connect(os.getenv("REDIS_HOST") or "127.0.0.1",
            tonumber(os.getenv("REDIS_PORT")) or 6379)

        if not ok then
            error("Connection failed: " .. tostring(err))
        end

        local res, ping_err = red:ping()
        if not res then
            error("PING failed: " .. tostring(ping_err))
        end

        local info = red:info("server")

        red:set_keepalive(10000, 100)

        return { enabled = true, connected = true, ping = res, info = info }
    end)

    status.response_time_ms = math.floor((ngx.now() - start_time) * 1000)

    if not success then
        status.status = "degraded"
        status.error = "Redis not available: " .. tostring(result)
        status.details.connected = false
        return status
    end

    status.details = result
    return status
end

-- Check MinIO connectivity
-- Verifies both internal (MINIO_ENDPOINT — used by the app for S3 operations)
-- and external (MINIO_ENDPOINT_WEB_EXTERNAL — used by browsers/clients for public access).
-- "healthy" = both pass, "degraded" = one passes, "unhealthy" = neither passes.
function HealthCheck.checkMinio()
    local start_time = ngx.now()
    local status = {
        name = "minio",
        status = "healthy",
        response_time_ms = 0,
        details = {}
    }

    -- Internal: the endpoint the app uses for S3 operations (container-to-container)
    local minio_internal = os.getenv("MINIO_ENDPOINT")
        or os.getenv("MINIO_INTERNAL_ENDPOINT")
        or "http://minio:9000"
    -- External: server-accessible public endpoint (set on deployed environments)
    -- Falls back to MINIO_PUBLIC_URL but skips localhost URLs (browser-only, not reachable from container)
    local minio_external = os.getenv("MINIO_ENDPOINT_WEB_EXTERNAL")
    if not minio_external or minio_external == "" then
        local public_url = os.getenv("MINIO_PUBLIC_URL")
        if public_url and public_url ~= "" and not public_url:match("localhost") and not public_url:match("127%.0%.0%.1") then
            minio_external = public_url
        end
    end

    status.details.internal_endpoint = minio_internal
    status.details.external_endpoint = minio_external or "(not configured)"

    -- SSL verification: enabled via HEALTH_CHECK_SSL_VERIFY=true (default: false)
    local ssl_env = os.getenv("HEALTH_CHECK_SSL_VERIFY")
    local ssl_verify = ssl_env == "true" or ssl_env == "1"
    status.details.ssl_verify = ssl_verify

    -- Helper: try a single MinIO health request
    local function check_endpoint(url)
        if not url or url == "" then
            return { connected = false, error = "Not configured" }
        end
        local ok, result = pcall(function()
            local httpc = http.new()
            httpc:set_timeout(5000)
            -- Resolve K8s DNS hostnames (e.g. .svc.cluster.local) to IP
            local resolved_url = resolve_for_health_check(url)
            local res, err = httpc:request_uri(resolved_url .. "/minio/health/live", {
                method = "GET",
                ssl_verify = ssl_verify,
            })
            if not res then
                error("Connection failed: " .. tostring(err))
            end
            return { connected = true, http_code = res.status }
        end)
        if ok then
            return result
        end
        return { connected = false, error = tostring(result) }
    end

    -- Check both endpoints
    local internal_result = check_endpoint(minio_internal)
    status.details.internal = internal_result
    local internal_healthy = internal_result.connected and internal_result.http_code == 200

    local external_result = check_endpoint(minio_external)
    status.details.external = external_result
    local external_healthy = external_result.connected and external_result.http_code == 200

    status.response_time_ms = math.floor((ngx.now() - start_time) * 1000)

    local external_configured = minio_external and minio_external ~= ""

    if internal_healthy and (external_healthy or not external_configured) then
        -- Internal works, and external either works or wasn't configured — all good
        status.details.connected = true
    elseif internal_healthy and external_configured and not external_healthy then
        -- App can talk to MinIO but public access is broken
        status.status = "degraded"
        status.details.connected = true
        status.error = "MinIO external endpoint not reachable (internal OK)"
    elseif external_healthy and not internal_healthy then
        -- External works but internal is broken — app S3 operations may fail
        status.status = "degraded"
        status.details.connected = true
        status.error = "MinIO internal endpoint not reachable (external OK)"
    else
        -- Neither works
        status.status = "unhealthy"
        status.details.connected = false
        status.error = "MinIO not reachable on any endpoint"
    end

    return status
end

-- Check file system access (important for uploads)
function HealthCheck.checkFileSystem()
    local start_time = ngx.now()
    local status = {
        name = "filesystem",
        status = "healthy",
        response_time_ms = 0,
        details = {}
    }

    local success, result = pcall(function()
        -- Check if upload directory is writable
        local upload_dir = "/tmp/opsapi-health-check"
        local test_file = upload_dir .. "/test-" .. ngx.time() .. ".txt"

        -- Create directory if it doesn't exist
        os.execute("mkdir -p " .. upload_dir)

        -- Try to write a test file
        local file = io.open(test_file, "w")
        if not file then
            error("Cannot write to upload directory")
        end

        file:write("health check test")
        file:close()

        -- Try to read the file back
        local read_file = io.open(test_file, "r")
        if not read_file then
            error("Cannot read from upload directory")
        end
        local content = read_file:read("*all")
        read_file:close()

        -- Clean up
        os.remove(test_file)

        return {
            writable = true,
            readable = true,
            test_passed = content == "health check test"
        }
    end)

    status.response_time_ms = math.floor((ngx.now() - start_time) * 1000)

    if not success then
        status.status = "unhealthy"
        status.error = "File system check failed: " .. tostring(result)
        status.details.writable = false
        return status
    end

    status.details = result
    return status
end

-- Check migrations status
function HealthCheck.checkMigrations()
    local status = {
        name = "migrations",
        status = "healthy",
        details = {}
    }

    local success, result = pcall(function()
        -- Check if migrations table exists
        local migrations = db.query("SELECT COUNT(*) as count FROM lapis_migrations")
        return {
            migrations_applied = migrations[1].count,
            migrations_table_exists = true
        }
    end)

    if not success then
        status.status = "unhealthy"
        status.error = "Cannot check migrations: " .. tostring(result)
        return status
    end

    status.details = result
    return status
end

-- Check system resources
function HealthCheck.checkSystemResources()
    local status = {
        name = "system",
        status = "healthy",
        details = {}
    }

    -- Memory usage
    local memory_kb = collectgarbage("count")
    status.details.memory_usage_kb = math.floor(memory_kb)
    status.details.memory_usage_mb = math.floor(memory_kb / 1024)

    -- Check if memory usage is too high (> 500MB)
    if memory_kb > 512000 then
        status.status = "degraded"
        status.warning = "High memory usage detected"
    end

    -- Uptime
    status.details.uptime_seconds = ngx.now()

    -- Worker info
    status.details.worker_pid = ngx.worker.pid()
    status.details.worker_count = ngx.worker.count()

    return status
end

-- Comprehensive health check
function HealthCheck.getFullStatus()
    local overall_start = ngx.now()

    local checks = {
        HealthCheck.checkDatabase(),
        HealthCheck.checkMinio(),
        HealthCheck.checkRedis(),
        HealthCheck.checkFileSystem(),
        HealthCheck.checkMigrations(),
        HealthCheck.checkSystemResources()
    }

    -- Determine overall status
    local overall_status = "healthy"
    local unhealthy_count = 0
    local degraded_count = 0

    for _, check in ipairs(checks) do
        if check.status == "unhealthy" then
            unhealthy_count = unhealthy_count + 1
            overall_status = "unhealthy"
        elseif check.status == "degraded" then
            degraded_count = degraded_count + 1
            if overall_status == "healthy" then
                overall_status = "degraded"
            end
        end
    end

    local total_time_ms = math.floor((ngx.now() - overall_start) * 1000)

    return {
        status = overall_status,
        timestamp = ngx.time(),
        timestamp_iso = os.date("!%Y-%m-%dT%H:%M:%SZ"),
        version = "1.0.0",
        environment = os.getenv("LAPIS_ENVIRONMENT") or "development",
        total_checks = #checks,
        unhealthy_checks = unhealthy_count,
        degraded_checks = degraded_count,
        total_response_time_ms = total_time_ms,
        checks = checks
    }
end

-- Quick health check (database + minio)
function HealthCheck.getQuickStatus()
    local db_check = HealthCheck.checkDatabase()
    local minio_check = HealthCheck.checkMinio()

    -- Database is critical (unhealthy = overall unhealthy)
    -- MinIO is important but not critical (unhealthy = overall degraded)
    local overall = "healthy"
    if db_check.status == "unhealthy" then
        overall = "unhealthy"
    elseif db_check.status == "degraded"
        or minio_check.status == "degraded"
        or minio_check.status == "unhealthy" then
        overall = "degraded"
    end

    return {
        status = overall,
        timestamp = ngx.time(),
        timestamp_iso = os.date("!%Y-%m-%dT%H:%M:%SZ"),
        version = "1.0.0",
        environment = os.getenv("LAPIS_ENVIRONMENT") or "development",
        services = {
            database = {
                status = db_check.status,
                response_time_ms = db_check.response_time_ms,
                version = db_check.details and db_check.details.version or nil,
                database_name = db_check.details and db_check.details.database_name or nil,
                database_size = db_check.details and db_check.details.database_size or nil,
            },
            minio = {
                status = minio_check.status,
                response_time_ms = minio_check.response_time_ms,
                connected = minio_check.details and minio_check.details.connected or false,
                error = minio_check.error,
            }
        }
    }
end

return HealthCheck
