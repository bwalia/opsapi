local respond_to = require("lapis.application").respond_to
local RoleQueries = require "queries.RoleQueries"

return function(app)
    app:match("roles", "/api/v2/roles", respond_to({
        GET = function(self)
            self.params.timestamp = true
            return { json = RoleQueries.all(self.params) }
        end,
        POST = function(self)
            return { json = RoleQueries.create(self.params), status = 201 }
        end
    }))

    app:match("edit_role", "/api/v2/roles/:id", respond_to({
        before = function(self)
            self.role = RoleQueries.show(self.params.id)
            if not self.role then
                self:write({ json = { error = "Role not found!" }, status = 404 })
            end
        end,
        GET = function(self)
            return { json = self.role, status = 200 }
        end,
        PUT = function(self)
            return { json = RoleQueries.update(self.params.id, self.params), status = 204 }
        end,
        DELETE = function(self)
            return { json = RoleQueries.destroy(self.params.id), status = 204 }
        end
    }))
end
