local lapis = require("lapis")
local app = lapis.Application()

local lapis = require("lapis")
local app = lapis.Application()

-- Add error handler for debugging
app:enable("etlua")
app.handle_error = function(self, err, trace)
    ngx.log(ngx.ERR, "Error: " .. tostring(err))
    ngx.log(ngx.ERR, "Trace: " .. tostring(trace))
    return { status = 500, json = { error = tostring(err) } }
end

app:enable("etlua")

-- Enable CORS for all routes
local CorsMiddleware = require("middleware.cors")
CorsMiddleware.enable(app)

require("routes.index")(app)
require("routes.auth")(app)
require("routes.users")(app)
require("routes.roles")(app)
require("routes.groups")(app)
require("routes.module")(app)
require("routes.permissions")(app)
require("routes.documents")(app)
require("routes.secrets")(app)
require("routes.tags")(app)
require("routes.templates")(app)
require("routes.projects")(app)
require("routes.enquiries")(app)
require("routes.stores")(app)
require("routes.categories")(app)
require("routes.storeproducts")(app)
require("routes.customers")(app)
require("routes.orders")(app)
require("routes.orderitems")(app)
require("routes.register")(app)
require("routes.cart")(app)
require("routes.checkout")(app)
require("routes.variants")(app)
require("routes.products")(app)
require("routes.payments")(app)
require("routes.stripe-webhook")(app)  -- Stripe webhook handler

require("routes.order_management")(app)  -- Enhanced seller order management
require("routes.order-status")(app)  -- Order status workflow management
require("routes.buyer-orders")(app)  -- Buyer order management
require("routes.notifications")(app)  -- Notifications system
require("routes.public-store")(app)  -- Public store profiles
return app
