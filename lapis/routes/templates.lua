local respond_to = require("lapis.application").respond_to
local TemplateQueries = require "queries.TemplateQueries"

return function(app)
    app:match("templates", "/api/v2/templates", respond_to({
        GET = function(self)
            self.params.timestamp = true
            local templates = TemplateQueries.all(self.params)
            return {
                json = templates,
                status = 200
            }
        end,
        POST = function(self)
            local project = TemplateQueries.create(self.params)
            return {
                json = project,
                status = 201
            }
        end
    }))

    app:match("edit_templates", "/api/v2/templates/:id", respond_to({
        before = function(self)
            self.project = TemplateQueries.show(tostring(self.params.id))
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
            local project = TemplateQueries.show(tostring(self.params.id))
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
            local project = TemplateQueries.update(tostring(self.params.id), self.params)
            return {
                json = project,
                status = 204
            }
        end,
        DELETE = function(self)
            local project = TemplateQueries.destroy(tostring(self.params.id))
            return {
                json = project,
                status = 204
            }
        end
    }))
end
