local respond_to = require("lapis.application").respond_to
local StoreproductQueries = require "queries.StoreproductQueries"

return function(app)
    app:match("storeproducts", "/api/v2/storeproducts", respond_to({
        GET = function(self)
            return { json = StoreproductQueries.all(self.params) }
        end,
        POST = function(self)
            return { json = StoreproductQueries.create(self.params), status = 201 }
        end
    }))

    app:match("edit_storeproduct", "/api/v2/storeproducts/:id", respond_to({
        before = function(self)
            self.storeproduct = StoreproductQueries.show(tostring(self.params.id))
            if not self.storeproduct then
                self:write({ json = { error = "Storeproduct not found!" }, status = 404 })
            end
        end,
        GET = function(self)
            return { json = self.storeproduct, status = 200 }
        end,
        PUT = function(self)
            return { json = StoreproductQueries.update(self.params.id, self.params), status = 204 }
        end,
        DELETE = function(self)
            return { json = StoreproductQueries.destroy(self.params.id), status = 204 }
        end
    }))
end
