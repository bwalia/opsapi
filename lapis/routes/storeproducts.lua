--[[
    Store Product Routes

    SECURITY: All endpoints require JWT authentication via AuthMiddleware.
    User identity is derived from the validated JWT token.
]]

local respond_to = require("lapis.application").respond_to
local StoreproductQueries = require "queries.StoreproductQueries"
local AuthMiddleware = require("middleware.auth")

return function(app)
    app:match("storeproducts", "/api/v2/storeproducts", respond_to({
        before = AuthMiddleware.requireAuthBefore,

        GET = function(self)
            return { json = StoreproductQueries.all(self.params) }
        end,
        POST = function(self)
            return { json = StoreproductQueries.create(self.params), status = 201 }
        end
    }))

    app:match("edit_storeproduct", "/api/v2/storeproducts/:id", respond_to({
        before = function(self)
            -- First authenticate
            AuthMiddleware.requireAuthBefore(self)
            if self.res and self.res.status then return end

            self.storeproduct = StoreproductQueries.show(tostring(self.params.id))
            if not self.storeproduct then
                self:write({ json = { error = "Store product not found" }, status = 404 })
            end
        end,
        GET = function(self)
            return { json = self.storeproduct, status = 200 }
        end,
        PUT = function(self)
            return { json = StoreproductQueries.update(self.params.id, self.params), status = 200 }
        end,
        DELETE = function(self)
            StoreproductQueries.destroy(self.params.id)
            return { json = { message = "Store product deleted successfully" }, status = 200 }
        end
    }))
end
