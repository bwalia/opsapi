local respond_to = require("lapis.application").respond_to
local ProductVariantQueries = require "queries.ProductVariantQueries"
local AuthMiddleware = require "middleware.auth"
local StoreproductQueries = require "queries.StoreproductQueries"

return function(app)
    app:match("variants", "/api/v2/products/:product_id/variants", respond_to({
        GET = function(self)
            return { json = ProductVariantQueries.all(self.params.product_id) }
        end,
        POST = AuthMiddleware.requireRole("seller", function(self)
            local product = StoreproductQueries.show(self.params.product_id)
            if not product then
                return { json = { error = "Product not found" }, status = 404 }
            end
            -- Verify store ownership
            product:get_store()
            if product.store and product.store.user_id ~= self.user_data.internal_id then
                return { json = { error = "Access denied - not your product" }, status = 403 }
            end

            self.params.product_id = product.uuid
            return { json = ProductVariantQueries.create(self.params), status = 201 }
        end)
    }))

    app:match("edit_variant", "/api/v2/variants/:id", respond_to({
        before = function(self)
            self.variant = ProductVariantQueries.show(tostring(self.params.id))
            if not self.variant then
                self:write({ json = { error = "Variant not found!" }, status = 404 })
            end
        end,
        GET = function(self)
            return { json = self.variant, status = 200 }
        end,
        PUT = AuthMiddleware.requireRole("seller", function(self)
            local product = self.variant:get_product()
            -- Verify store ownership
            product:get_store()
            if product.store and product.store.user_id ~= self.user_data.internal_id then
                return { json = { error = "Access denied - not your product" }, status = 403 }
            end

            return { json = ProductVariantQueries.update(self.params.id, self.params), status = 200 }
        end),
        DELETE = AuthMiddleware.requireRole("seller", function(self)
            local product = self.variant:get_product()
            -- Verify store ownership
            product:get_store()
            if product.store and product.store.user_id ~= self.user_data.internal_id then
                return { json = { error = "Access denied - not your product" }, status = 403 }
            end

            return { json = ProductVariantQueries.destroy(self.params.id), status = 200 }
        end)
    }))
end