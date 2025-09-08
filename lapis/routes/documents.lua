local respond_to = require("lapis.application").respond_to
local DocumentQueries = require "queries.DocumentQueries"
return function(app)
    app:get("/api/v2/all-documents", function(self)
        self.params.timestamp = true
        local records = DocumentQueries.allData()
        return {
            json = records,
            status = 200
        }
    end)

    app:match("documents", "/api/v2/documents", respond_to({
        GET = function(self)
            self.params.timestamp = true
            local records = DocumentQueries.all(self.params)
            return {
                json = records,
                status = 200
            }
        end,
        POST = function(self)
            local record = DocumentQueries.create(self.params and self.params or self.POST)
            return {
                json = record,
                status = 201
            }
        end,
        DELETE = function(self)
            local record = DocumentQueries.deleteMultiple(self.params)
            return {
                json = record,
                status = 200
            }
        end
    }))

    app:match("edit_documents", "/api/v2/documents/:id", respond_to({
        before = function(self)
            self.record = DocumentQueries.show(tostring(self.params.id))
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
            local record = DocumentQueries.show(tostring(self.params.id))
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
                        error = "assert_valid was not captured: " ..
                                "Please pass the uuid of document that you want to update"
                    },
                    status = 500
                }
            end
            local record = DocumentQueries.update(tostring(self.params.id), self.params)
            return {
                json = record,
                status = 200
            }
        end,
        DELETE = function(self)
            local record = DocumentQueries.destroy(tostring(self.params.id))
            return {
                json = record,
                status = 204
            }
        end
    }))
end
