local lapis = require("lapis")
local app = lapis.Application()
local CorsMiddleware = require("middleware.cors")
local GlobalRateLimit = require("middleware.global-rate-limit")

-- Enable CORS
CorsMiddleware.enable(app)

-- Enable global rate limiting (OPSAPI_RATE_LIMIT_DEFAULT env, default 10000/minute)
-- Also logs X-Proxy-Pop-Code so we can trace edge location per request.
GlobalRateLimit.enable(app)

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
                docs = "/docs",
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

    -- Public auth routes (no authentication required)
    -- Note: /auth/refresh handles its own token validation for refresh flow
    local public_auth_routes = {
        ["/auth/login"] = true,
        ["/auth/register"] = true,
        ["/auth/forgot-password"] = true,
        ["/auth/reset-password"] = true,
        ["/auth/verify-email"] = true,
        ["/auth/resend-verification"] = true,
        ["/auth/refresh"] = true,         -- Handles its own token validation
        ["/auth/2fa/verify"] = true,      -- 2FA OTP verification (pre-auth)
        ["/auth/2fa/resend"] = true,      -- 2FA resend OTP (pre-auth)
        ["/auth/google"] = true,          -- Google OAuth initiation
        ["/auth/google/callback"] = true, -- Google OAuth callback
        ["/auth/oauth/validate"] = true,  -- OAuth token validation
        ["/auth/hmrc/callback"] = true,   -- HMRC MTD OAuth callback
        ["/auth/logout"] = true,         -- Logout (revokes refresh token)
    }

    -- Skip auth for public routes
    if uri == "/" or uri == "/health" or uri == "/ready" or uri == "/live" or
        uri == "/swagger" or uri == "/api-docs" or uri == "/openapi.json" or
        uri == "/swagger/swagger.json" or uri == "/metrics" or public_auth_routes[uri] or
        uri:match("^/api/v2/public/") or
        uri:match("^/api/v2/delivery/fee%-estimate") or uri:match("^/api/v2/delivery/pricing%-config$") or
        uri:match("^/api/v2/test%-notification") then
        ngx.log(ngx.DEBUG, "Skipping auth for: ", uri)
        return
    end

    ngx.log(ngx.NOTICE, "Applying auth to: ", uri)
    local ok, auth = pcall(require, "helper.auth")
    if ok then
        auth.authenticate()
        -- Populate self.current_user from ngx.ctx.user for Lapis routes
        if ngx.ctx.user then
            self.current_user = ngx.ctx.user
            -- Ensure user has a default namespace (lazy assignment on first request)
            local ns_ok, ns_resolver = pcall(require, "helper.namespace-resolver")
            if ns_ok then
                pcall(ns_resolver.resolve, self.current_user)
            end
        end
    end
end)

-- ============================================
-- PROTECTED ROUTES (Feature-gated loading)
--
-- Routes are only loaded when their required feature is enabled
-- via PROJECT_CODE. This prevents 500 errors from querying
-- tables that don't exist for the current project.
-- ============================================

local ProjectConfig = require("helper.project-config")

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

-- Load routes only when their required feature is enabled
local function load_if(feature, route_name)
    if ProjectConfig.isFeatureEnabled(feature) then
        return safe_load_routes(route_name)
    else
        ngx.log(ngx.NOTICE, "Skipped (feature '", feature, "' disabled): ", route_name)
        return false
    end
end

ngx.log(ngx.NOTICE, "Loading routes (PROJECT_CODE=", ProjectConfig.getProjectCode(), ")...")

-- ============================================
-- CORE ROUTES (always loaded — core tables exist for all projects)
-- ============================================
safe_load_routes("routes.auth")
safe_load_routes("routes.pin")
safe_load_routes("routes.users")
safe_load_routes("routes.groups")
safe_load_routes("routes.roles")
safe_load_routes("routes.permissions")
safe_load_routes("routes.module")
safe_load_routes("routes.documents")
safe_load_routes("routes.secrets")
safe_load_routes("routes.tags")
safe_load_routes("routes.templates")
safe_load_routes("routes.projects")
safe_load_routes("routes.enquiries")
safe_load_routes("routes.register")
safe_load_routes("routes.namespaces")
safe_load_routes("routes.email")

-- ============================================
-- MENU SYSTEM (backend-driven navigation)
-- ============================================
load_if("menu", "routes.menu")

-- ============================================
-- ECOMMERCE (stores, products, orders, payments)
-- ============================================
load_if("ecommerce", "routes.products")
load_if("ecommerce", "routes.categories")
load_if("ecommerce", "routes.orders")
load_if("ecommerce", "routes.cart")
load_if("ecommerce", "routes.payments")
load_if("ecommerce", "routes.addresses")
load_if("ecommerce", "routes.stores")
load_if("ecommerce", "routes.storeproducts")
load_if("ecommerce", "routes.customers")
load_if("ecommerce", "routes.orderitems")
load_if("ecommerce", "routes.checkout")
load_if("ecommerce", "routes.variants")
load_if("ecommerce", "routes.stripe-webhook")
load_if("ecommerce", "routes.order_management")
load_if("ecommerce", "routes.order-status")
load_if("ecommerce", "routes.buyer-orders")
load_if("ecommerce", "routes.public-store")
load_if("ecommerce", "routes.tenants")

-- ============================================
-- DELIVERY PARTNER SYSTEM
-- ============================================
load_if("delivery", "routes.delivery-partners")
load_if("delivery", "routes.delivery-assignments")
load_if("delivery", "routes.delivery-requests")
load_if("delivery", "routes.delivery-partner-dashboard")
load_if("delivery", "routes.delivery-management")
load_if("delivery", "routes.store-delivery-partners")
load_if("delivery", "routes.delivery-partners-enhanced")
load_if("delivery", "routes.delivery-dashboard-enhanced")
load_if("delivery", "routes.delivery-partner-verification")
load_if("delivery", "routes.delivery-pricing")

-- ============================================
-- CHAT SYSTEM (Slack-like messaging)
-- ============================================
load_if("chat", "routes.chat-channels")
load_if("chat", "routes.chat-messages")
load_if("chat", "routes.chat-reactions")
load_if("chat", "routes.chat-mentions")
load_if("chat", "routes.chat-extras")

-- ============================================
-- KANBAN PROJECT MANAGEMENT
-- ============================================
load_if("kanban", "routes.kanban-projects")
load_if("kanban", "routes.kanban-boards")
load_if("kanban", "routes.kanban-tasks")
load_if("kanban", "routes.kanban-labels")
load_if("kanban", "routes.kanban-sprints")
load_if("kanban", "routes.kanban-time-tracking")
load_if("kanban", "routes.kanban-notifications")
load_if("kanban", "routes.kanban-analytics")

-- ============================================
-- NOTIFICATIONS (Push notifications, device tokens)
-- ============================================
load_if("notifications", "routes.notifications")
load_if("notifications", "routes.device-tokens")
load_if("notifications", "routes.test-notification")

-- ============================================
-- HOSPITAL & CARE HOME MANAGEMENT
-- ============================================
load_if("hospital", "routes.hospital-departments")
load_if("hospital", "routes.hospital-wards")
load_if("hospital", "routes.care-plans")
load_if("hospital", "routes.care-logs")
load_if("hospital", "routes.medications")
load_if("hospital", "routes.patient-access-controls")
load_if("hospital", "routes.family-members")
load_if("hospital", "routes.dementia-care")
load_if("hospital", "routes.daily-logs")
load_if("hospital", "routes.patient-alerts")
load_if("hospital", "routes.patient-audit-logs")

-- ============================================
-- SERVICES MODULE (GitHub Workflow Integration)
-- ============================================
load_if("services", "routes.services")

-- ============================================
-- SECRET VAULT
-- ============================================
load_if("vault", "routes.secret-vault")
load_if("vault", "routes.vault-providers")

-- ============================================
-- BANK TRANSACTIONS
-- ============================================
load_if("bank_transactions", "routes.bank_transactions")

-- ============================================
-- TAX COPILOT (UK Tax Return AI)
-- ============================================
load_if("tax_copilot", "routes.tax-bank-accounts")
load_if("tax_copilot", "routes.tax-statements")
load_if("tax_copilot", "routes.tax-transactions")
load_if("tax_copilot", "routes.tax-upload")
load_if("tax_copilot", "routes.tax-dashboard")
load_if("tax_copilot", "routes.tax-settings")
load_if("tax_copilot", "routes.tax-reports")
load_if("tax_copilot", "routes.tax-rates")
load_if("tax_copilot", "routes.tax-admin-transactions")
load_if("tax_copilot", "routes.tax-profile")
load_if("tax_copilot", "routes.tax-hmrc-auth")
load_if("tax_copilot", "routes.profile-builder")

-- ============================================
-- CRM (Accounts, Contacts, Deals, Pipelines)
-- ============================================
load_if("crm", "routes.crm-pipelines")
load_if("crm", "routes.crm-accounts")
load_if("crm", "routes.crm-contacts")
load_if("crm", "routes.crm-deals")
load_if("crm", "routes.crm-activities")

-- ============================================
-- TIMESHEETS (Time tracking and approval)
-- ============================================
load_if("timesheets", "routes.timesheets")

-- ============================================
-- INVOICING (Invoice generation and payments)
-- ============================================
load_if("invoicing", "routes.invoices")
load_if("invoicing", "routes.document-templates")

-- ============================================
-- ACCOUNTING / BOOKKEEPING (AI-powered)
-- ============================================
load_if("accounting", "routes.accounting")

-- ============================================
-- CUSTOM ROUTES (loaded from external directory)
-- ============================================
local custom_routes_dir = os.getenv("OPSAPI_CUSTOM_ROUTES_DIR")
if custom_routes_dir then
    ngx.log(ngx.NOTICE, "Loading custom routes from: ", custom_routes_dir)
    local custom_route_files = io.popen("ls " .. custom_routes_dir .. "/*.lua")
    if custom_route_files ~= nil then
        for file in custom_route_files:lines() do
            local route_name = file:match(".*/(.*)%.lua$")
            if route_name then
                local full_route_path = custom_routes_dir .. "." .. route_name
                safe_load_routes(full_route_path)
            end
        end
        custom_route_files:close()
    else
        ngx.log(ngx.ERR, "Failed to list custom routes in directory: ", custom_routes_dir)
    end
else
    ngx.log(ngx.NOTICE, "No custom routes directory specified.")
end
ngx.log(ngx.NOTICE, "All routes loaded")

return app
