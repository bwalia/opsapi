local respond_to = require("lapis.application").respond_to
local StoreproductQueries = require "queries.StoreproductQueries"
local AuthMiddleware = require "middleware.auth"

return function(app)
    -- Get all products with search and filtering (public)
    app:match("products", "/api/v2/products", respond_to({
        GET = function(self)
            local records = StoreproductQueries.searchProducts(self.params)
            return { json = records }
        end
    }))
    
    -- Get featured products (public)
    app:match("featured_products", "/api/v2/products/featured", respond_to({
        GET = function(self)
            local records = StoreproductQueries.getFeaturedProducts(self.params)
            return { json = records }
        end
    }))

    -- Get single product (public)
    app:match("show_product", "/api/v2/products/:id", respond_to({
        GET = function(self)
            local product = StoreproductQueries.show(tostring(self.params.id))
            if not product then
                return { json = { error = "Product not found" }, status = 404 }
            end
            return { json = product }
        end
    }))
    
    -- Update product (seller only)
    app:match("edit_product", "/api/v2/products/:id/edit", respond_to({
        PUT = AuthMiddleware.requireRole("seller", function(self)
            local product = StoreproductQueries.show(tostring(self.params.id))
            if not product then
                return { json = { error = "Product not found" }, status = 404 }
            end
            
            -- Verify store ownership
            product:get_store()
            if product.store and product.store.user_id ~= self.user_data.internal_id then
                return { json = { error = "Access denied - not your product" }, status = 403 }
            end
            
            local updated_product = StoreproductQueries.update(tostring(self.params.id), self.params)
            return { json = updated_product, status = 200 }
        end),
        
        DELETE = AuthMiddleware.requireRole("seller", function(self)
            local product = StoreproductQueries.show(tostring(self.params.id))
            if not product then
                return { json = { error = "Product not found" }, status = 404 }
            end
            
            -- Verify store ownership
            product:get_store()
            if product.store and product.store.user_id ~= self.user_data.internal_id then
                return { json = { error = "Access denied - not your product" }, status = 403 }
            end
            
            StoreproductQueries.destroy(tostring(self.params.id))
            return { json = { message = "Product deleted successfully" }, status = 200 }
        end)
    }))
end
