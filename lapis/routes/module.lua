--[[
    Module Routes

    SECURITY: All endpoints require JWT authentication via AuthMiddleware.
    User identity is derived from the validated JWT token.
]]

local respond_to = require("lapis.application").respond_to
local ModuleQueries = require "queries.ModuleQueries"
local AuthMiddleware = require("middleware.auth")

return function(app)
    app:match("modules", "/api/v2/modules", respond_to({
        before = AuthMiddleware.requireAuthBefore,

        GET = function(self)
            self.params.timestamp = true
            local modules = ModuleQueries.all(self.params)
            return {
                json = modules
            }
        end,
        POST = function(self)
            local module = ModuleQueries.create(self.params)
            return {
                json = module,
                status = 201
            }
        end
    }))

    app:match("edit_module", "/api/v2/modules/:id", respond_to({
        before = function(self)
            -- First authenticate
            AuthMiddleware.requireAuthBefore(self)
            if self.res and self.res.status then return end

            self.module = ModuleQueries.show(tostring(self.params.id))
            if not self.module then
                self:write({
                    json = { error = "Module not found! Please check the UUID and try again." },
                    status = 404
                })
            end
        end,
        GET = function(self)
            return {
                json = self.module,
                status = 200
            }
        end,
        PUT = function(self)
            local module = ModuleQueries.update(tostring(self.params.id), self.params)
            return {
                json = module,
                status = 200
            }
        end,
        DELETE = function(self)
            ModuleQueries.destroy(tostring(self.params.id))
            return {
                json = { message = "Module deleted successfully" },
                status = 200
            }
        end
    }))
end
