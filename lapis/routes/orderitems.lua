local respond_to = require("lapis.application").respond_to
local OrderitemQueries = require "queries.OrderitemQueries"
local AuthMiddleware = require "middleware.auth"

return function(app)
    app:match("orderitems", "/api/v2/orderitems", respond_to({
        GET = function(self)
            return { json = OrderitemQueries.all(self.params) }
        end,
        POST = AuthMiddleware.requireAuth(function(self)
            local success, result = pcall(function()
                return OrderitemQueries.create(self.params)
            end)

            if not success then
                return { json = { error = result }, status = 400 }
            end

            return { json = result, status = 201 }
        end)
    }))

    app:match("edit_orderitem", "/api/v2/orderitems/:id", respond_to({
        before = function(self)
            self.orderitem = OrderitemQueries.show(tostring(self.params.id))
            if not self.orderitem then
                self:write({ json = { error = "Orderitem not found!" }, status = 404 })
            end
        end,
        GET = function(self)
            return { json = self.orderitem, status = 200 }
        end,
        PUT = function(self)
            return { json = OrderitemQueries.update(self.params.id, self.params), status = 204 }
        end,
        DELETE = function(self)
            return { json = OrderitemQueries.destroy(self.params.id), status = 204 }
        end
    }))
end
