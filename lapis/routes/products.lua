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

    app:match("product", "/api/v2/products/:id", respond_to({
        GET = function(self)
            local product = StoreproductQueries.show(self.params.id)
            if not product then
                return { json = { error = "Product not found" }, status = 404 }
            end
            return { json = product }
        end,
        PUT = AuthMiddleware.requireRole("seller", function(self)
            local product = StoreproductQueries.show(self.params.id)
            if not product then
                return { json = { error = "Product not found" }, status = 404 }
            end

            -- Verify store ownership
            product:get_store()
            if product.store and product.store.user_id ~= self.user_data.internal_id then
                return { json = { error = "Access denied - not your product" }, status = 403 }
            end

            local updated = StoreproductQueries.update(self.params.id, self.params)
            return { json = updated }
        end),
        DELETE = AuthMiddleware.requireRole("seller", function(self)
            local product = StoreproductQueries.show(self.params.id)
            if not product then
                return { json = { error = "Product not found" }, status = 404 }
            end

            -- Verify store ownership
            product:get_store()
            if product.store and product.store.user_id ~= self.user_data.internal_id then
                return { json = { error = "Access denied - not your product" }, status = 403 }
            end

            StoreproductQueries.destroy(self.params.id)
            return { json = { message = "Product deleted successfully" } }
        end)
    }))
end