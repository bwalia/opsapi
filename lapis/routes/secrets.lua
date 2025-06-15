local respond_to = require("lapis.application").respond_to
local SecretQueries = require "queries.SecretQueries"
local Route = require("lapis.application").Route
local Global = require "helper.global"

return function(app)
    app:match("secrets", "/api/v2/secrets", respond_to({
        GET = function(self)
            self.params.timestamp = true
            local secrets = SecretQueries.all(self.params)
            return {
                json = secrets,
                status = 200
            }
        end,
        POST = function(self)
            local user = SecretQueries.create(self.params)
            return {
                json = user,
                status = 201
            }
        end
    }))

    app:match("edit_secrets", "/api/v2/secrets/:id", respond_to({
        before = function(self)
            self.user = SecretQueries.show(tostring(self.params.id))
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
            local user = SecretQueries.show(tostring(self.params.id))
            return {
                json = user,
                status = 200
            }
        end,
        PUT = function(self)
            if self.params.email or self.params.username or self.params.password then
                return {
                    json = {
                        lapis = {
                            version = require("lapis.version")
                        },
                        error = "assert_valid was not captured: You cannot update email, username or password directly"
                    },
                    status = 500
                }
            end
            if not self.params.id then
                return {
                    json = {
                        lapis = {
                            version = require("lapis.version")
                        },
                        error = "assert_valid was not captured: Please pass the uuid of user that you want to update"
                    },
                    status = 500
                }
            end
            local user = SecretQueries.update(tostring(self.params.id), self.params)
            return {
                json = user,
                status = 204
            }
        end,
        DELETE = function(self)
            local user = SecretQueries.destroy(tostring(self.params.id))
            return {
                json = user,
                status = 204
            }
        end
    }))

    app:get("/api/v2/secrets/:id/show", function(self)
        local group, status = SecretQueries.showSecret(self.params.id)
        return {
            json = group,
            status = status
        }
    end)
end
