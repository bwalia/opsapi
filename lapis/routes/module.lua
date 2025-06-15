local respond_to = require("lapis.application").respond_to
local ModuleQueries = require "queries.ModuleQueries"

return function(app)
    app:match("modules", "/api/v2/modules", respond_to({
        GET = function(self)
            self.params.timestamp = true
            local roles = ModuleQueries.all(self.params)
            return {
                json = roles
            }
        end,
        POST = function(self)
            local roles = ModuleQueries.create(self.params)
            return {
                json = roles,
                status = 201
            }
        end
    }))

    app:match("edit_module", "/api/v2/modules/:id", respond_to({
        before = function(self)
            self.role = ModuleQueries.show(tostring(self.params.id))
            if not self.role then
                self:write({
                    json = {
                        lapis = {
                            version = require("lapis.version")
                        },
                        error = "Role not found! Please check the UUID and try again."
                    },
                    status = 404
                })
            end
        end,
        GET = function(self)
            local role = ModuleQueries.show(tostring(self.params.id))
            return {
                json = role,
                status = 200
            }
        end,
        PUT = function(self)
            local role = ModuleQueries.update(tostring(self.params.id), self.params)
            return {
                json = role,
                status = 204
            }
        end,
        DELETE = function(self)
            local role = ModuleQueries.destroy(tostring(self.params.id))
            return {
                json = role,
                status = 204
            }
        end
    }))
end
