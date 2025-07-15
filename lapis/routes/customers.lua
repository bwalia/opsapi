local respond_to = require("lapis.application").respond_to
local CustomerQueries = require "queries.CustomerQueries"

return function(app)
    app:match("customers", "/api/v2/customers", respond_to({
        GET = function(self)
            return { json = CustomerQueries.all(self.params) }
        end,
        POST = function(self)
            return { json = CustomerQueries.create(self.params), status = 201 }
        end
    }))

    app:match("edit_customer", "/api/v2/customers/:id", respond_to({
        before = function(self)
            self.customer = CustomerQueries.show(tostring(self.params.id))
            if not self.customer then
                self:write({ json = { error = "Customer not found!" }, status = 404 })
            end
        end,
        GET = function(self)
            return { json = self.customer, status = 200 }
        end,
        PUT = function(self)
            return { json = CustomerQueries.update(self.params.id, self.params), status = 204 }
        end,
        DELETE = function(self)
            return { json = CustomerQueries.destroy(self.params.id), status = 204 }
        end
    }))
end
