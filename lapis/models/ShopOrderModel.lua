local Model = require("lapis.db.model").Model

-- Thin model for shop_orders (Workstation AI Shop). Business logic lives in queries/Shop*Queries.lua.
local ShopOrder = Model:extend("shop_orders", { timestamp = true })

return ShopOrder
