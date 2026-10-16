--[[
    Secrets Routes (Admin Only)

    SECURITY: All endpoints require authentication and admin role.
    These routes manage API secrets and sensitive credentials.
]]

local SecretQueries = require "queries.SecretQueries"
local AuthMiddleware = require("middleware.auth")

return function(app)
    -- Platform admins only: the exact "administrative" role, checked against the database too (AdminCheck).
    -- It used to match any role whose name contains "admin" (e.g. tax_admin) and trusted the token alone.
    local function is_admin(user)
        return require("helper.admin-check").isPlatformAdmin(user)
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
        if not secret then
            return { json = { error = "Secret not found" }, status = 404 }
        end
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

        if not SecretQueries.destroy(tostring(self.params.id)) then
            return { json = { error = "Secret not found" }, status = 404 }
        end
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
