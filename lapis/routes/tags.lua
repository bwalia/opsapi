local respond_to = require("lapis.application").respond_to
local TagsQueries = require "queries.TagsQueries"

return function(app)
    app:match("tags", "/api/v2/tags", respond_to({
        GET = function(self)
            self.params.timestamp = true
            local records = TagsQueries.all(self.params)
            return {
                json = records,
                status = 200
            }
        end,
        POST = function(self)
            local record = TagsQueries.create(self.params)
            return {
                json = record,
                status = 201
            }
        end
    }))

    app:match("edit_tags", "/api/v2/tags/:id", respond_to({
        before = function(self)
            self.record = TagsQueries.show(tostring(self.params.id))
            if not self.record then
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
            local record = TagsQueries.show(tostring(self.params.id))
            return {
                json = record,
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
                        error = "assert_valid was not captured: Please pass the uuid of document that you want to update"
                    },
                    status = 500
                }
            end
            local record = TagsQueries.update(tostring(self.params.id), self.params)
            return {
                json = record,
                status = 204
            }
        end,
        DELETE = function(self)
            local record = TagsQueries.destroy(tostring(self.params.id))
            return {
                json = record,
                status = 204
            }
        end
    }))
end
