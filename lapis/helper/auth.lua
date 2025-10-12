local jwt = require("resty.jwt")
local Global = require("helper.global")

local _M = {}

-- Public routes that do not require authentication
local PUBLIC_ROUTES = {
    ["^/$"] = true,
    ["^/health$"] = true,
    ["^/swagger$"] = true,
    ["^/api%-docs$"] = true,
    ["^/openapi%.json$"] = true,
    ["^/swagger/swagger%.json$"] = true,
    ["^/metrics$"] = true,
    ["^/auth/login$"] = true,
    ["^/auth/register$"] = true,
    -- ["^/auth/forgot_password$"] = true,
    -- ["^/auth/reset_password$"] = true}

function _M.is_public_route(uri)
    for pattern, _ in pairs(PUBLIC_ROUTES) do
        if ngx.re.match(uri, pattern) then
            ngx.log(ngx.NOTICE, "Public route matched: ", uri, " with pattern: ", pattern)
            return true
        end
    end
    ngx.log(ngx.NOTICE, "Not a public route: ", uri)
    return false
end

function _M.authenticate()
    local uri = ngx.var.uri
    
    -- Skip authentication for public routes
    if _M.is_public_route(uri) then
        ngx.log(ngx.NOTICE, "Skipping authentication for public route: ", uri)
        return
    end
    
    ngx.log(ngx.NOTICE, "Protected route, checking authentication: ", uri)
    
    -- Get Authorization header
    local auth_header = ngx.var.http_authorization
    
    if not auth_header then
        ngx.log(ngx.WARN, "Missing Authorization header for: ", uri)
        ngx.status = 401
        ngx.header.content_type = "application/json"
        ngx.say('{"error":"Missing Authorization header"}')
        ngx.exit(401)
    end
    
    -- Extract token
    local token = auth_header:match("Bearer%s+(.+)")
    
    if not token then
        ngx.status = 401
        ngx.header.content_type = "application/json"
        ngx.say('{"error":"Invalid Authorization format. Use: Bearer <token>"}')
        ngx.exit(401)
    end
    
    -- Verify JWT
    local JWT_SECRET_KEY = Global.getEnvVar("JWT_SECRET_KEY")
    if not JWT_SECRET_KEY then
        ngx.log(ngx.ERR, "JWT_SECRET_KEY not configured")
        ngx.status = 500
        ngx.header.content_type = "application/json"
        ngx.say('{"error":"Authentication not configured"}')
        ngx.exit(500)
    end
    
    local jwt_obj = jwt:verify(JWT_SECRET_KEY, token)
    
    if not jwt_obj.verified then
        ngx.log(ngx.WARN, "JWT verification failed: ", jwt_obj.reason)
        ngx.status = 401
        ngx.header.content_type = "application/json"
        ngx.say('{"error":"Invalid or expired token","reason":"' .. (jwt_obj.reason or "unknown") .. '"}')
        ngx.exit(401)
    end
    
    -- Store user info in ngx.ctx
    ngx.ctx.user = jwt_obj.payload.userinfo
    ngx.log(ngx.NOTICE, "Authentication successful for user: ", tostring(ngx.ctx.user and ngx.ctx.user.uuid or "unknown"))
end

return _M
