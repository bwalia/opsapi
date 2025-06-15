local respond_to = require("lapis.application").respond_to
local PermissionQueries = require "queries.PermissionQueries"

return function(app)
    app:match("permissions", "/api/v2/permissions", respond_to({
        GET = function(self)
            self.params.timestamp = true
            local roles = PermissionQueries.all(self.params)
            return {
                json = roles
            }
        end,
        POST = function(self)
            local roles = PermissionQueries.create(self.params)
            return {
                json = roles,
                status = 201
            }
        end
    }))

    app:match("edit_permission", "/api/v2/permissions/:id", respond_to({
        before = function(self)
            self.role = PermissionQueries.show(tostring(self.params.id))
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
            local role = PermissionQueries.show(tostring(self.params.id))
            return {
                json = role,
                status = 200
            }
        end,
        PUT = function(self)
            local role = PermissionQueries.update(tostring(self.params.id), self.params)
            return {
                json = role,
                status = 204
            }
        end,
        DELETE = function(self)
            local role = PermissionQueries.destroy(tostring(self.params.id))
            return {
                json = role,
                status = 204
            }
        end
    }))
end
