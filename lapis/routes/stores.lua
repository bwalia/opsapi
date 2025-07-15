local respond_to = require("lapis.application").respond_to
local StoreQueries = require "queries.StoreQueries"
local AuthMiddleware = require "middleware.auth"

return function(app)
    -- Public store listing
    app:match("stores", "/api/v2/stores", respond_to({
        GET = function(self)
            return { json = StoreQueries.all(self.params) }
        end,
        POST = AuthMiddleware.requireRole("seller", function(self)
            self.params.user_id = self.user_data.internal_id
            return { json = StoreQueries.create(self.params), status = 201 }
        end)
    }))
    
    -- User's own stores
    app:match("my_stores", "/api/v2/users/:user_id/stores", respond_to({
        GET = function(self)
            return { json = StoreQueries.getByUser(self.params.user_id, self.params) }
        end
    }))

    app:match("edit_store", "/api/v2/stores/:id", respond_to({
        before = function(self)
            self.store = StoreQueries.show(tostring(self.params.id))
            if not self.store then
                self:write({ json = { error = "Store not found!" }, status = 404 })
            end
        end,
        GET = function(self)
            return { json = self.store, status = 200 }
        end,
        PUT = function(self)
            if self.params.user_id and self.store.user_id ~= tonumber(self.params.user_id) then
                return { json = { error = "Access denied" }, status = 403 }
            end
            return { json = StoreQueries.update(self.params.id, self.params), status = 204 }
        end,
        DELETE = function(self)
            if self.params.user_id and self.store.user_id ~= tonumber(self.params.user_id) then
                return { json = { error = "Access denied" }, status = 403 }
            end
            return { json = StoreQueries.destroy(self.params.id), status = 204 }
        end
    }))
    
    -- Store products
    app:match("store_products", "/api/v2/stores/:store_id/products", respond_to({
        GET = function(self)
            local StoreproductQueries = require "queries.StoreproductQueries"
            return { json = StoreproductQueries.getByStore(self.params.store_id, self.params) }
        end,
        POST = AuthMiddleware.requireRole("seller", function(self)
            local StoreproductQueries = require "queries.StoreproductQueries"
            self.params.store_id = self.params.store_id
            return { json = StoreproductQueries.create(self.params), status = 201 }
        end)
    }))
end
