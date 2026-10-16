--[[
    Order items (raw table access): platform admins only.

    Nothing in the dashboard or the storefront calls these: checkout, payments and the Stripe webhook create items
    in code, and a store reads them through GET /api/v2/orders/:id. They used to have no permission or ownership
    check, so any signed-in user could list every tenant's order items and change their prices or move them
    between orders. An update changes only the fields below; never the order, product, variant or uuid.
]]
local respond_to = require("lapis.application").respond_to
local OrderitemQueries = require "queries.OrderitemQueries"
local AuthMiddleware = require "middleware.auth"
local AdminCheck = require "helper.admin-check"

local UPDATABLE = { "quantity", "price", "total", "product_title", "variant_title", "sku" }

local function admin_only(handler)
    return AuthMiddleware.requireAuth(function(self)
        if not AdminCheck.isPlatformAdmin(self.current_user) then
            return { json = { error = "Access denied. Admin privileges required." }, status = 403 }
        end
        return handler(self)
    end)
end

return function(app)
    app:match("orderitems", "/api/v2/orderitems", respond_to({
        GET = admin_only(function(self)
            return { json = OrderitemQueries.all(self.params) }
        end),
        POST = admin_only(function(self)
            local success, result = pcall(function()
                return OrderitemQueries.create(self.params)
            end)

            if not success then
                return { json = { error = result }, status = 400 }
            end

            return { json = result, status = 201 }
        end)
    }))

    local function load(self)
        self.orderitem = OrderitemQueries.show(tostring(self.params.id))
        if not self.orderitem then return { json = { error = "Orderitem not found!" }, status = 404 } end
    end

    app:match("edit_orderitem", "/api/v2/orderitems/:id", respond_to({
        GET = admin_only(function(self)
            local missing = load(self); if missing then return missing end
            return { json = self.orderitem, status = 200 }
        end),
        PUT = admin_only(function(self)
            local missing = load(self); if missing then return missing end
            local changes = require("helper.global").pick(self.params, UPDATABLE)
            return { json = OrderitemQueries.update(self.params.id, changes), status = 200 }
        end),
        DELETE = admin_only(function(self)
            local missing = load(self); if missing then return missing end
            return { json = OrderitemQueries.destroy(self.params.id), status = 204 }
        end)
    }))
end
