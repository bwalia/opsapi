--[[
    Store Product Routes

    SECURITY: All endpoints require JWT auth AND a namespace context. Data is
    scoped to self.namespace.id — the list is filtered and every :id operation
    verifies the product belongs to the caller's namespace, so one tenant can
    never read/modify another tenant's products.
]]

local respond_to = require("lapis.application").respond_to
local StoreproductQueries = require "queries.StoreproductQueries"
local AuthMiddleware = require("middleware.auth")
local NamespaceMiddleware = require("middleware.namespace")

-- Load the product for :id routes and enforce tenant ownership.
-- Returns a 404 response table when missing or cross-tenant; nil when OK.
local function load_owned(self)
    self.storeproduct = StoreproductQueries.show(tostring(self.params.id))
    if not self.storeproduct then
        return { json = { error = "Store product not found" }, status = 404 }
    end
    if tonumber(self.storeproduct.namespace_id) ~= tonumber(self.namespace.id) then
        return { json = { error = "Store product not found" }, status = 404 }
    end
end

return function(app)
    app:match("storeproducts", "/api/v2/storeproducts", respond_to({
        GET = AuthMiddleware.requireAuth(NamespaceMiddleware.requireNamespace(function(self)
            self.params.namespace_id = self.namespace.id
            return { json = StoreproductQueries.all(self.params) }
        end)),
        POST = AuthMiddleware.requireAuth(NamespaceMiddleware.requireNamespace(function(self)
            self.params.namespace_id = self.namespace.id
            return { json = StoreproductQueries.create(self.params), status = 201 }
        end)),
    }))

    app:match("edit_storeproduct", "/api/v2/storeproducts/:id", respond_to({
        GET = AuthMiddleware.requireAuth(NamespaceMiddleware.requireNamespace(function(self)
            local denied = load_owned(self); if denied then return denied end
            return { json = self.storeproduct, status = 200 }
        end)),
        PUT = AuthMiddleware.requireAuth(NamespaceMiddleware.requireNamespace(function(self)
            local denied = load_owned(self); if denied then return denied end
            return { json = StoreproductQueries.update(self.params.id, self.params), status = 200 }
        end)),
        DELETE = AuthMiddleware.requireAuth(NamespaceMiddleware.requireNamespace(function(self)
            local denied = load_owned(self); if denied then return denied end
            StoreproductQueries.destroy(self.params.id)
            return { json = { message = "Store product deleted successfully" }, status = 200 }
        end)),
    }))
end
