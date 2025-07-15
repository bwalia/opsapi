local respond_to = require("lapis.application").respond_to
local OrderQueries = require "queries.OrderQueries"
local AuthMiddleware = require "middleware.auth"

return function(app)
    app:match("orders", "/api/v2/orders", respond_to({
        GET = function(self)
            return { json = OrderQueries.all(self.params) }
        end,
        POST = AuthMiddleware.requireAuth(function(self)
            return { json = OrderQueries.create(self.params), status = 201 }
        end)
    }))

    app:match("edit_order", "/api/v2/orders/:id", respond_to({
        before = function(self)
            self.order = OrderQueries.show(tostring(self.params.id))
            if not self.order then
                self:write({ json = { error = "Order not found!" }, status = 404 })
            end
        end,
        GET = function(self)
            return { json = self.order, status = 200 }
        end,
        PUT = function(self)
            return { json = OrderQueries.update(self.params.id, self.params), status = 204 }
        end,
        DELETE = function(self)
            return { json = OrderQueries.destroy(self.params.id), status = 204 }
        end
    }))
end
