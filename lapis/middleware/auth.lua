local jwt = require("resty.jwt")
local Global = require("helper.global")
local UserQueries = require("queries.UserQueries")

local AuthMiddleware = {}

function AuthMiddleware.authenticate(self)
    local auth_header = self.req.headers["authorization"]
    if not auth_header then
        return nil, { error = "Authorization header required", status = 401 }
    end

    local token = auth_header:match("Bearer%s+(.+)")
    if not token then
        return nil, { error = "Invalid authorization format", status = 401 }
    end

    local JWT_SECRET_KEY = Global.getEnvVar("JWT_SECRET_KEY")
    if not JWT_SECRET_KEY then
        return nil, { error = "JWT secret not configured", status = 500 }
    end

    local jwt_obj = jwt:verify(JWT_SECRET_KEY, token)
    if not jwt_obj or not jwt_obj.verified then
        return nil, { error = "Invalid or expired token: " .. (jwt_obj and jwt_obj.reason or "unknown"), status = 401 }
    end

    local user_info = jwt_obj.payload.userinfo
    if not user_info then
        return nil, { error = "Invalid token payload", status = 401 }
    end

    return user_info, nil
end

function AuthMiddleware.requireAuth(handler)
    return function(self)
        ngx.log(ngx.INFO, "=== AUTH MIDDLEWARE CALLED for: " .. (self.req.parsed_url.path or "unknown"))
        
        -- Check for public browse header
        local public_browse = self.req.headers["x-public-browse"]
        if public_browse and public_browse:lower() == "true" then
            ngx.log(ngx.INFO, "Public browse access granted")
            -- Allow public access without authentication
            self.current_user = nil
            self.is_public_browse = true
            return handler(self)
        end

        local user, err = AuthMiddleware.authenticate(self)
        if err then
            ngx.log(ngx.INFO, "Authentication failed: " .. (err.error or "unknown error"))
            return { json = { error = err.error }, status = err.status }
        end

        ngx.log(ngx.INFO, "Authentication successful for user: " .. (user.uuid or user.sub or "unknown"))
        self.current_user = user
        return handler(self)
    end
end

function AuthMiddleware.requireRole(role, handler)
    return function(self)
        -- Note: role-based endpoints require authentication regardless of public browse setting
        -- This is a security measure for endpoints that check user roles

        local user, err = AuthMiddleware.authenticate(self)
        if err then
            return { json = { error = err.error }, status = err.status }
        end

        if not user then
            return { json = { error = "User information missing" }, status = 401 }
        end

        local user_data = UserQueries.show(user.sub or user.uuid)
        if not user_data or not user_data.roles then
            return { json = { error = "User roles not found" }, status = 403 }
        end

        local has_role = false
        for _, user_role in ipairs(user_data.roles) do
            if user_role.name == role then
                has_role = true
                break
            end
        end

        if not has_role then
            return { json = { error = "Insufficient permissions" }, status = 403 }
        end

        self.current_user = user
        self.user_data = user_data
        return handler(self)
    end
end

return AuthMiddleware
