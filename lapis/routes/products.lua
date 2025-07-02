local respond_to = require("lapis.application").respond_to
local ProductQueries = require "queries.ProductQueries"

return function(app)
    app:match("products", "/api/v2/products", respond_to({
        GET = function(self)
            self.params.timestamp = true
            local records = ProductQueries.all(self.params)
            return {
                json = records
            }
        end,
        POST = function(self)
            local record = ProductQueries.create(self.params)
            return {
                json = record,
                status = 201
            }
        end
    }))

    app:match("edit_product", "/api/v2/products/:id", respond_to({
        before = function(self)
            self.product = ProductQueries.show(tostring(self.params.id))
            if not self.product then
                self:write({
                    json = {
                        lapis = {
                            version = require("lapis.version")
                        },
                        error = "Product not found! Please check the UUID and try again."
                    },
                    status = 404
                })
            end
        end,
        GET = function(self)
            local record = ProductQueries.show(tostring(self.params.id))
            return {
                json = record,
                status = 200
            }
        end,
        PUT = function(self)
            local record = ProductQueries.update(tostring(self.params.id), self.params)
            return {
                json = record,
                status = 204
            }
        end,
        DELETE = function(self)
            local record = ProductQueries.destroy(tostring(self.params.id))
            return {
                json = record,
                status = 204
            }
        end
    }))
end
