local respond_to = require("lapis.application").respond_to
local StoreproductQueries = require "queries.StoreproductQueries"
local AuthMiddleware = require "middleware.auth"
local StoreQueries = require "queries.StoreQueries"

return function(app)
    app:match("products", "/api/v2/products", respond_to({
        GET = function(self)
            local records = StoreproductQueries.searchProducts(self.params)
            return { json = records }
        end,
        POST = AuthMiddleware.requireRole("seller", function(self)
            -- Verify store ownership
            local store = StoreQueries.showByUUID(self.params.store_id)
            if not store or store.user_id ~= self.user_data.internal_id then
                return { json = { error = "Access denied - not your store" }, status = 403 }
            end
            
            local product, err = pcall(StoreproductQueries.create, self.params)
            if not product then
                return { json = { error = err }, status = 400 }
            end
            
            return { json = product, status = 201 }
        end)
    }))
end