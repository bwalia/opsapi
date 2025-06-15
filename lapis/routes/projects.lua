local respond_to = require("lapis.application").respond_to
local ProjectQueries = require "queries.ProjectQueries"

return function(app)
    app:match("projects", "/api/v2/projects", respond_to({
        GET = function(self)
            self.params.timestamp = true
            local projects = ProjectQueries.all(self.params)
            return {
                json = projects,
                status = 200
            }
        end,
        POST = function(self)
            local project = ProjectQueries.create(self.params)
            return {
                json = project,
                status = 201
            }
        end
    }))

    app:match("edit_projects", "/api/v2/projects/:id", respond_to({
        before = function(self)
            self.project = ProjectQueries.show(tostring(self.params.id))
            if not self.project then
                self:write({
                    json = {
                        lapis = {
                            version = require("lapis.version")
                        },
                        error = "Project not found! Please check the UUID and try again."
                    },
                    status = 404
                })
            end
        end,
        GET = function(self)
            local project = ProjectQueries.show(tostring(self.params.id))
            return {
                json = project,
                status = 200
            }
        end,
        PUT = function(self)
            if not self.params.id then
                return {
                    json = {
                        lapis = {
                            version = require("lapis.version")
                        },
                        error = "assert_valid was not captured: Please pass the uuid of project that you want to update"
                    },
                    status = 500
                }
            end
            local project = ProjectQueries.update(tostring(self.params.id), self.params)
            return {
                json = project,
                status = 204
            }
        end,
        DELETE = function(self)
            local project = ProjectQueries.destroy(tostring(self.params.id))
            return {
                json = project,
                status = 204
            }
        end
    }))
end
