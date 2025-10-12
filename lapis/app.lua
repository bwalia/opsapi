local lapis = require("lapis")
local app = lapis.Application()

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

app:get("/health", function(self)
    return {
        json = {
            status = "healthy",
            timestamp = ngx.time(),
            version = "1.0.0"
        }
    }
end)

app:get("/swagger", function(self)
    return { render = "swagger" }
end)

app:get("/api-docs", function(self)
    return { render = "swagger" }
end)

-- THIS IS THE KEY FIX - Make sure openapi.json is truly public
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

-- ============================================
-- AUTH MIDDLEWARE - Only for routes below
-- ============================================

app:before_filter(function(self)
    local uri = ngx.var.uri
    
    -- Double-check: Skip auth for public routes
    if uri == "/" or uri == "/health" or uri == "/swagger" or 
       uri == "/api-docs" or uri == "/openapi.json" or uri == "/metrics" or
       uri:match("^/auth/") then
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
        ngx.log(ngx.ERR, "Failed to load: ", route_name)
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

-- Load all routes
ngx.log(ngx.NOTICE, "Loading routes...")

safe_load_routes("routes.index")

safe_load_routes("routes.auth")
safe_load_routes("routes.users")
safe_load_routes("routes.groups")
safe_load_routes("routes.roles")
safe_load_routes("routes.customers")
safe_load_routes("routes.products")
safe_load_routes("routes.categories")
safe_load_routes("routes.orders")
safe_load_routes("routes.cart")
safe_load_routes("routes.orderitems")
safe_load_routes("routes.payments")
safe_load_routes("routes.addresses")
safe_load_routes("routes.tenants")
safe_load_routes("routes.permissions")
safe_load_routes("routes.hospitals")
safe_load_routes("routes.patients")
safe_load_routes("routes.module")
safe_load_routes("routes.documents")
safe_load_routes("routes.secrets")
safe_load_routes("routes.tags")
safe_load_routes("routes.templates")
safe_load_routes("routes.projects")
safe_load_routes("routes.enquiries")
safe_load_routes("routes.stores")
safe_load_routes("routes.categories")
safe_load_routes("routes.storeproducts")
safe_load_routes("routes.register")
safe_load_routes("routes.checkout")
safe_load_routes("routes.variants")
safe_load_routes("routes.products")
safe_load_routes("routes.payments")

-- order management
safe_load_routes("routes.stripe-webhook")   -- Stripe webhook handler
safe_load_routes("routes.order_management") -- Enhanced seller order management
safe_load_routes("routes.order-status") -- Order status workflow management
safe_load_routes("routes.buyer-orders") -- Buyer order management
safe_load_routes("routes.notifications")
safe_load_routes("routes.public-store") -- Public store profiles

-- delivery management

safe_load_routes("routes.delivery-partners")    -- Delivery partner registration & profile
safe_load_routes("routes.delivery-assignments") -- Delivery assignment management
safe_load_routes("routes.delivery-requests") -- Delivery request system
safe_load_routes("routes.delivery-partner-dashboard") -- Delivery partner dashboard & earnings
safe_load_routes("routes.store-delivery-partners")

return app
