-- Professional Health Check System
-- Production-ready health checks for all critical services

local db = require("lapis.db")
local redis = require("resty.redis")

local HealthCheck = {}

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

    -- Get database statistics
    local stats_success, stats_result = pcall(function()
        local db_stats = db.query([[
            SELECT
                (SELECT COUNT(*) FROM orders) as total_orders,
                (SELECT COUNT(*) FROM stores) as total_stores,
                (SELECT COUNT(*) FROM users) as total_users,
                pg_database_size(current_database()) as database_size
        ]])
        return db_stats[1]
    end)

    if stats_success and stats_result then
        status.details.total_orders = stats_result.total_orders or 0
        status.details.total_stores = stats_result.total_stores or 0
        status.details.total_users = stats_result.total_users or 0
        status.details.database_size_bytes = stats_result.database_size or 0
    end

    return status
end

-- Check Redis connection (if configured)
function HealthCheck.checkRedis()
    local start_time = ngx.now()
    local status = {
        name = "redis",
        status = "healthy",
        response_time_ms = 0,
        details = {}
    }

    local success, result = pcall(function()
        local red = redis:new()
        red:set_timeout(1000) -- 1 second timeout

        -- Try to connect to Redis
        local ok, err = red:connect(os.getenv("REDIS_HOST") or "127.0.0.1",
                                    tonumber(os.getenv("REDIS_PORT")) or 6379)

        if not ok then
            error("Connection failed: " .. tostring(err))
        end

        -- Test PING command
        local res, err = red:ping()
        if not res then
            error("PING failed: " .. tostring(err))
        end

        -- Get Redis info
        local info, err = red:info("server")

        -- Close connection
        red:set_keepalive(10000, 100)

        return { connected = true, ping = res, info = info }
    end)

    status.response_time_ms = math.floor((ngx.now() - start_time) * 1000)

    if not success then
        status.status = "degraded"  -- Redis is optional, so degraded instead of unhealthy
        status.error = "Redis not available: " .. tostring(result)
        status.details.connected = false
        return status
    end

    status.details = result
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

-- Quick health check (just database)
function HealthCheck.getQuickStatus()
    local db_check = HealthCheck.checkDatabase()

    return {
        status = db_check.status,
        timestamp = ngx.time(),
        version = "1.0.0",
        database = {
            status = db_check.status,
            response_time_ms = db_check.response_time_ms
        }
    }
end

return HealthCheck
