local Model = require("lapis.db.model").Model

-- Thin model for shop_stripe_events (Workstation AI Shop). Business logic lives in queries/Shop*Queries.lua.
local ShopStripeEvent = Model:extend("shop_stripe_events", { timestamp = true })

return ShopStripeEvent
