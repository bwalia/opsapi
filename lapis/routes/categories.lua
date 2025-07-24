local respond_to = require("lapis.application").respond_to
local CategoryQueries = require "queries.CategoryQueries"
local AuthMiddleware = require "middleware.auth"
local StoreQueries = require "queries.StoreQueries"

return function(app)
    app:match("categories", "/api/v2/categories", respond_to({
        GET = function(self)
            return { json = CategoryQueries.all(self.params) }
        end,
        POST = AuthMiddleware.requireRole("seller", function(self)   
            -- Verify store ownership if store_id is provided
            if self.params.store_id then
                local store = StoreQueries.showByOwner(self.params.store_id, self.user_data.internal_id)
                if not store then
                    return { json = { error = "Access denied - not your store" }, status = 403 }
                end
            end
            return { json = CategoryQueries.create(self.params), status = 201 }
        end)
    }))

    app:match("edit_category", "/api/v2/categories/:id", respond_to({
        before = function(self)
            self.category = CategoryQueries.show(tostring(self.params.id))
            if not self.category then
                self:write({ json = { error = "Category not found!" }, status = 404 })
            end
        end,
        GET = function(self)
            return { json = self.category, status = 200 }
        end,
        PUT = AuthMiddleware.requireRole("seller", function(self)
            -- Verify store ownership through category
            if self.category.store_id then
                local store = StoreQueries.showByOwner(self.category.store_id, self.user_data.internal_id)
                if not store then
                    return { json = { error = "Access denied - not your store" }, status = 403 }
                end
            end
            return { json = CategoryQueries.update(self.params.id, self.params), status = 200 }
        end),
        DELETE = AuthMiddleware.requireRole("seller", function(self)
            -- Verify store ownership through category
            if self.category.store_id then
                local store = StoreQueries.showByOwner(self.category.store_id, self.user_data.internal_id)
                if not store then
                    return { json = { error = "Access denied - not your store" }, status = 403 }
                end
            end
            return { json = CategoryQueries.destroy(self.params.id), status = 200 }
        end)
    }))
end
