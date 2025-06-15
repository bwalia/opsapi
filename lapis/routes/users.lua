local respond_to = require("lapis.application").respond_to
local UserQueries = require "queries.UserQueries"
local Global = require "helper.global"

return function(app)
    app:match("users", "/api/v2/users", respond_to({
        GET = function(self)
            self.params.timestamp = true
            return { json = UserQueries.all(self.params), status = 200 }
        end,
        POST = function(self)
            return { json = UserQueries.create(self.params), status = 201 }
        end
    }))

    app:match("edit_user", "/api/v2/users/:id", respond_to({
        before = function(self)
            self.user = UserQueries.show(tostring(self.params.id))
            if not self.user then
                self:write({
                    json = { error = "User not found!" },
                    status = 404
                })
            end
        end,
        GET = function(self)
            return { json = self.user, status = 200 }
        end,
        PUT = function(self)
            return { json = UserQueries.update(self.params.id, self.params), status = 204 }
        end,
        DELETE = function(self)
            return { json = UserQueries.destroy(self.params.id), status = 204 }
        end
    }))

    ----------------- SCIM User Routes --------------------
    app:match("scim_users", "/scim/v2/Users", respond_to({
        GET = function(self)
            self.params.timestamp = true
            local users = UserQueries.SCIMall(self.params)
            return {
                json = users,
                status = 200
            }
        end,
        POST = function(self)
            local user = UserQueries.SCIMcreate(self.params)
            return {
                json = user,
                status = 201
            }
        end
    }))

    app:match("edit_scim_user", "/scim/v2/Users/:id", respond_to({
        before = function(self)
            self.user = UserQueries.show(tostring(self.params.id))
            if not self.user then
                self:write({
                    json = {
                        lapis = {
                            version = require("lapis.version")
                        },
                        error = "User not found! Please check the UUID and try again."
                    },
                    status = 404
                })
            end
        end,
        GET = function(self)
            local user = UserQueries.show(tostring(self.params.id))
            return {
                json = user,
                status = 200
            }
        end,
        PUT = function(self)
            local content_type = self.req.headers["content-type"]
            local body = self.params
            if content_type == "application/json" then
                ngx.req.read_body()
                body = Global.getPayloads(ngx.req.get_post_args())
            end
            local user, status = UserQueries.SCIMupdate(tostring(self.params.id), body)
            return {
                json = user,
                status = status
            }
        end,
        DELETE = function(self)
            local user = UserQueries.destroy(tostring(self.params.id))
            return {
                json = user,
                status = 204
            }
        end
    }))
end
