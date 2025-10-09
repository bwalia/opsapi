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
       uri == "/api-docs" or uri == "/openapi.json" or 
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

ngx.log(ngx.NOTICE, "All routes loaded")

return app
