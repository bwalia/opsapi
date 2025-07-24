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
            -- Use the authenticated user's internal ID
            self.params.user_id = self.user_data.internal_id
            return { json = StoreQueries.create(self.params), status = 201 }
        end)
    }))
    
    -- User's own stores (authenticated)
    app:match("my_stores", "/api/v2/my/stores", respond_to({
        GET = AuthMiddleware.requireAuth(function(self)
            -- Get user data to get internal ID
            local user_data = require("queries.UserQueries").show(self.current_user.sub or self.current_user.uuid)
            if not user_data then
                return { json = { error = "User not found" }, status = 404 }
            end
            return { json = StoreQueries.getByUser(user_data.internal_id, self.params) }
        end)
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
        PUT = AuthMiddleware.requireAuth(function(self)
            -- Get current user info
            local user_data = require("queries.UserQueries").show(self.current_user.sub or self.current_user.uuid)
            if not user_data or self.store.user_id ~= user_data.internal_id then
                return { json = { error = "Access denied" }, status = 403 }
            end
            return { json = StoreQueries.update(self.params.id, self.params), status = 200 }
        end),
        DELETE = AuthMiddleware.requireAuth(function(self)
            -- Get current user info
            local user_data = require("queries.UserQueries").show(self.current_user.sub or self.current_user.uuid)
            if not user_data or self.store.user_id ~= user_data.internal_id then
                return { json = { error = "Access denied" }, status = 403 }
            end
            return { json = StoreQueries.destroy(self.params.id), status = 200 }
        end)
    }))
    
    -- Store products
    app:match("store_products", "/api/v2/stores/:store_id/products", respond_to({
        GET = function(self)
            local StoreproductQueries = require "queries.StoreproductQueries"
            return { json = StoreproductQueries.getByStore(self.params.store_id, self.params) }
        end,
        POST = AuthMiddleware.requireRole("seller", function(self)
            -- Verify store ownership
            local store = StoreQueries.show(self.params.store_id)
            if not store or store.user_id ~= self.user_data.internal_id then
                return { json = { error = "Access denied - not your store" }, status = 403 }
            end
            
            local StoreproductQueries = require "queries.StoreproductQueries"
            self.params.store_id = self.params.store_id
            return { json = StoreproductQueries.create(self.params), status = 201 }
        end)
    }))
end
