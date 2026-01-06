--[[
    Secrets Routes (Admin Only)

    SECURITY: All endpoints require authentication and admin role.
    These routes manage API secrets and sensitive credentials.
]]

local SecretQueries = require "queries.SecretQueries"
local AuthMiddleware = require("middleware.auth")

return function(app)
    -- Helper to check if user is admin
    local function is_admin(user)
        if not user then return false end

        -- Check roles array
        if user.roles then
            if type(user.roles) == "string" then
                return user.roles:lower():find("admin") ~= nil
            elseif type(user.roles) == "table" then
                for _, role in ipairs(user.roles) do
                    local role_name = type(role) == "string" and role or (role.role_name or role.name or "")
                    if role_name:lower():find("admin") then
                        return true
                    end
                end
            end
        end

        return false
    end

    -- List all secrets (Admin only)
    app:get("/api/v2/secrets", AuthMiddleware.requireAuth(function(self)
        if not is_admin(self.current_user) then
            return {
                json = { error = "Access denied. Admin privileges required." },
                status = 403
            }
        end

        self.params.timestamp = true
        local secrets = SecretQueries.all(self.params)
        return {
            json = secrets,
            status = 200
        }
    end))

    -- Create a secret (Admin only)
    app:post("/api/v2/secrets", AuthMiddleware.requireAuth(function(self)
        if not is_admin(self.current_user) then
            return {
                json = { error = "Access denied. Admin privileges required." },
                status = 403
            }
        end

        local secret = SecretQueries.create(self.params)
        return {
            json = secret,
            status = 201
        }
    end))

    -- Get a single secret (Admin only)
    app:get("/api/v2/secrets/:id", AuthMiddleware.requireAuth(function(self)
        if not is_admin(self.current_user) then
            return {
                json = { error = "Access denied. Admin privileges required." },
                status = 403
            }
        end

        local secret = SecretQueries.show(tostring(self.params.id))
        if not secret then
            return {
                json = { error = "Secret not found" },
                status = 404
            }
        end

        return {
            json = secret,
            status = 200
        }
    end))

    -- Update a secret (Admin only)
    app:put("/api/v2/secrets/:id", AuthMiddleware.requireAuth(function(self)
        if not is_admin(self.current_user) then
            return {
                json = { error = "Access denied. Admin privileges required." },
                status = 403
            }
        end

        if not self.params.id then
            return {
                json = { error = "Secret ID is required" },
                status = 400
            }
        end

        local secret = SecretQueries.update(tostring(self.params.id), self.params)
        return {
            json = secret,
            status = 200
        }
    end))

    -- Delete a secret (Admin only)
    app:delete("/api/v2/secrets/:id", AuthMiddleware.requireAuth(function(self)
        if not is_admin(self.current_user) then
            return {
                json = { error = "Access denied. Admin privileges required." },
                status = 403
            }
        end

        SecretQueries.destroy(tostring(self.params.id))
        return {
            json = { message = "Secret deleted successfully" },
            status = 200
        }
    end))

    -- Show secret value (Admin only) - Extra sensitive
    app:get("/api/v2/secrets/:id/show", AuthMiddleware.requireAuth(function(self)
        if not is_admin(self.current_user) then
            return {
                json = { error = "Access denied. Admin privileges required." },
                status = 403
            }
        end

        local secret, status = SecretQueries.showSecret(self.params.id)
        return {
            json = secret,
            status = status
        }
    end))
end
