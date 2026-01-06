local lapis = require("lapis")
local app = lapis.Application()
local CorsMiddleware = require("middleware.cors")

-- Enable CORS
CorsMiddleware.enable(app)

-- Enable etlua
app:enable("etlua")
app.views_prefix = "views"

-- Error handler
app.handle_error = function(self, err, trace)
    ngx.log(ngx.ERR, "Application Error: ", tostring(err))
    ngx.log(ngx.ERR, "Stack Trace: ", tostring(trace))
    return {
        status = 500,
        json = {
            error = "Internal server error",
            message = tostring(err)
        }
    }
end

-- ============================================
-- PUBLIC ROUTES - NO AUTH
-- ============================================

app:get("/", function(self)
    return {
        json = {
            message = "OpsAPI is running",
            version = "1.0.0",
            endpoints = {
                documentation = "/swagger",
                health = "/health",
                openapi = "/openapi.json",
                login = "/auth/login"
            }
        }
    }
end)

-- Professional Health Check Endpoint
app:get("/health", function(self)
    local ok, HealthCheck = pcall(require, "helper.health-check")
    if not ok then
        ngx.log(ngx.ERR, "Failed to load health-check module: ", tostring(HealthCheck))
        return {
            status = 503,
            json = {
                status = "unhealthy",
                error = "Health check module not available",
                timestamp = ngx.time()
            }
        }
    end

    -- Check if detailed parameter is provided
    local detailed = self.params.detailed == "true" or self.params.detailed == "1"

    local health_status
    if detailed then
        -- Full comprehensive health check
        health_status = HealthCheck.getFullStatus()
    else
        -- Quick health check (just database)
        health_status = HealthCheck.getQuickStatus()
    end

    -- Set HTTP status code based on health
    local http_status = 200
    if health_status.status == "unhealthy" then
        http_status = 503 -- Service Unavailable
    elseif health_status.status == "degraded" then
        http_status = 200 -- OK but with warnings
    end

    return {
        status = http_status,
        json = health_status
    }
end)

-- Readiness probe (for Kubernetes)
app:get("/ready", function(self)
    local ok, HealthCheck = pcall(require, "helper.health-check")
    if not ok then
        return { status = 503, json = { ready = false, error = "Health check unavailable" } }
    end

    local db_check = HealthCheck.checkDatabase()

    if db_check.status == "healthy" then
        return { status = 200, json = { ready = true, timestamp = ngx.time() } }
    else
        return { status = 503, json = { ready = false, reason = db_check.error or "Database unhealthy" } }
    end
end)

-- Liveness probe (for Kubernetes)
app:get("/live", function(self)
    -- Basic liveness check - just verify the app is running
    return {
        status = 200,
        json = {
            alive = true,
            timestamp = ngx.time(),
            uptime_seconds = ngx.now()
        }
    }
end)

app:get("/swagger", function(self)
    return { render = "swagger" }
end)

app:get("/api-docs", function(self)
    return { render = "swagger" }
end)

-- OpenAPI spec
app:get("/openapi.json", function(self)
    ngx.log(ngx.NOTICE, "=== Serving /openapi.json - NO AUTH REQUIRED ===")
    ngx.header["Access-Control-Allow-Origin"] = "*"

    local ok, openapi_gen = pcall(require, "helper.openapi_generator")
    if not ok then
        ngx.log(ngx.ERR, "Failed to load openapi_generator: ", tostring(openapi_gen))
        return { status = 500, json = { error = "Generator not found" } }
    end

    local spec = openapi_gen.generate()
    return { status = 200, json = spec }
end)

-- Alternative OpenAPI spec path
app:get("/swagger/swagger.json", function(self)
    ngx.log(ngx.NOTICE, "=== Serving /swagger/swagger.json - NO AUTH REQUIRED ===")
    ngx.header["Access-Control-Allow-Origin"] = "*"

    local ok, openapi_gen = pcall(require, "helper.openapi_generator")
    if not ok then
        ngx.log(ngx.ERR, "Failed to load openapi_generator: ", tostring(openapi_gen))
        return { status = 500, json = { error = "Generator not found" } }
    end

    local spec = openapi_gen.generate()
    return { status = 200, json = spec }
end)

-- Prometheus Metrics
app:get("/metrics", function(self)
    ngx.log(ngx.NOTICE, "=== Serving /metrics ===")
    ngx.header["Content-Type"] = "text/plain; version=0.0.4"
    ngx.header["Access-Control-Allow-Origin"] = "*"

    return {
        layout = false,
        [[# HELP opsapi_up API is running
# TYPE opsapi_up gauge
opsapi_up 1

# HELP opsapi_info API information
# TYPE opsapi_info gauge
opsapi_info{version="1.0.0"} 1

# HELP opsapi_memory_usage_bytes Memory usage in bytes
# TYPE opsapi_memory_usage_bytes gauge
opsapi_memory_usage_bytes ]] .. (collectgarbage("count") * 1024) .. [[


# HELP opsapi_uptime_seconds API uptime in seconds
# TYPE opsapi_uptime_seconds counter
opsapi_uptime_seconds ]] .. ngx.now() .. [[

]]
    }
end)

-- ============================================
-- AUTH MIDDLEWARE
-- ============================================

app:before_filter(function(self)
    local uri = ngx.var.uri

    -- Skip auth for public routes
    if uri == "/" or uri == "/health" or uri == "/ready" or uri == "/live" or
        uri == "/swagger" or uri == "/api-docs" or uri == "/openapi.json" or
        uri == "/swagger/swagger.json" or uri == "/metrics" or uri:match("^/auth/") or
        uri:match("^/api/v2/public/") or
        uri:match("^/api/v2/delivery/fee%-estimate") or uri:match("^/api/v2/delivery/pricing%-config$") then
        ngx.log(ngx.DEBUG, "Skipping auth for: ", uri)
        return
    end

    ngx.log(ngx.NOTICE, "Applying auth to: ", uri)
    local ok, auth = pcall(require, "helper.auth")
    if ok then
        auth.authenticate()
    end
end)

-- ============================================
-- PROTECTED ROUTES
-- ============================================

local function safe_load_routes(route_name)
    local ok, route_module = pcall(require, route_name)
    if not ok then
        ngx.log(ngx.ERR, "Failed to load: ", route_name, " - Error: ", tostring(route_module))
        return false
    end

    local ok_init, err = pcall(route_module, app)
    if not ok_init then
        ngx.log(ngx.ERR, "Failed to init: ", route_name, " - ", tostring(err))
        return false
    end

    ngx.log(ngx.NOTICE, "Loaded: ", route_name)
    return true
end

ngx.log(ngx.NOTICE, "Loading routes...")

safe_load_routes("routes.auth")
safe_load_routes("routes.users")
safe_load_routes("routes.groups")
safe_load_routes("routes.roles")
safe_load_routes("routes.products")
safe_load_routes("routes.categories")
safe_load_routes("routes.orders")
safe_load_routes("routes.cart")
safe_load_routes("routes.payments")
safe_load_routes("routes.addresses")
safe_load_routes("routes.tenants")
safe_load_routes("routes.permissions")






safe_load_routes("routes.module")

safe_load_routes("routes.documents")
safe_load_routes("routes.secrets")
safe_load_routes("routes.tags")
safe_load_routes("routes.templates")
safe_load_routes("routes.projects")
safe_load_routes("routes.enquiries")
safe_load_routes("routes.stores")
safe_load_routes("routes.storeproducts")
safe_load_routes("routes.customers")
safe_load_routes("routes.orderitems")
safe_load_routes("routes.register")

safe_load_routes("routes.checkout")
safe_load_routes("routes.variants")


safe_load_routes("routes.stripe-webhook")   -- Stripe webhook ha

safe_load_routes("routes.order_management") -- Enhanced seller order management
safe_load_routes("routes.order-status")     -- Order status workflow management
safe_load_routes("routes.buyer-orders")     -- Buyer order management
safe_load_routes("routes.notifications")    -- Notifications system
safe_load_routes("routes.public-store")     -- Public store products

-- Delivery Partner System (Legacy)
safe_load_routes("routes.delivery-partners")          -- Delivery partner registration & profile
safe_load_routes("routes.delivery-assignments")       -- Delivery assignments management
safe_load_routes("routes.delivery-requests")          -- Delivery requests management
safe_load_routes("routes.delivery-partner-dashboard") -- Delivery partner dashboard
safe_load_routes("routes.delivery-management")        -- Professional delivery management (accept, update status)
safe_load_routes("routes.store-delivery-partners")    -- Store delivery partner associations

-- Enhanced Delivery Partner System (Geolocation-Based)
safe_load_routes("routes.delivery-partners-enhanced")    -- Geolocation registration & profile
safe_load_routes("routes.delivery-dashboard-enhanced")   -- Geo-based dashboard with nearby orders
safe_load_routes("routes.delivery-partner-verification") -- Verification system with document upload

-- Delivery Pricing System
safe_load_routes("routes.delivery-pricing") -- Professional delivery fee calculation & validation

-- Chat System (Slack-like messaging)
safe_load_routes("routes.chat-channels")  -- Channel management (create, update, members)
safe_load_routes("routes.chat-messages")  -- Message operations (send, edit, delete, threads)
safe_load_routes("routes.chat-reactions") -- Message reactions (add, remove, toggle)
safe_load_routes("routes.chat-mentions")  -- Mentions API (list, read, autocomplete)
safe_load_routes("routes.chat-extras")    -- Bookmarks, drafts, presence, invites, files

-- Namespace System (Multi-tenant)
safe_load_routes("routes.namespaces") -- Namespace management, members, roles, switching

-- Menu System (Backend-driven navigation)
safe_load_routes("routes.menu") -- User menu based on permissions

-- Services Module (GitHub Workflow Integration)
safe_load_routes("routes.services") -- Service management, secrets, deployments, GitHub workflows

-- Kanban Project Management System (Integrated with Chat)
safe_load_routes("routes.kanban-projects")      -- Projects, members, starred
safe_load_routes("routes.kanban-boards")        -- Boards, columns, reordering
safe_load_routes("routes.kanban-tasks")         -- Tasks, assignments, comments, checklists, attachments
safe_load_routes("routes.kanban-labels")        -- Project labels
safe_load_routes("routes.kanban-sprints")       -- Sprint management, burndown, velocity
safe_load_routes("routes.kanban-time-tracking") -- Time tracking, timers, timesheets
safe_load_routes("routes.kanban-notifications") -- Notifications, preferences
safe_load_routes("routes.kanban-analytics")     -- Project analytics, activity feed, reports

-- Fetch the value of OPSAPI_CUSTOM_ROUTES_DIR environment variable
local custom_routes_dir = os.getenv("OPSAPI_CUSTOM_ROUTES_DIR")
if custom_routes_dir then
    ngx.log(ngx.NOTICE, "Loading custom routes from: ", custom_routes_dir)
    local custom_route_files = io.popen("ls " .. custom_routes_dir .. "/*.lua")
    for file in custom_route_files:lines() do
        local route_name = file:match(".*/(.*)%.lua$")
        if route_name then
            local full_route_path = custom_routes_dir .. "." .. route_name
            safe_load_routes(full_route_path)
        end
    end
    custom_route_files:close()
else
    ngx.log(ngx.NOTICE, "No custom routes directory specified.")
end
ngx.log(ngx.NOTICE, "All routes loaded")

return app
