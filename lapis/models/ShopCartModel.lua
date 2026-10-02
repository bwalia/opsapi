local Model = require("lapis.db.model").Model

-- Thin model for shop_carts (Workstation AI Shop). Business logic lives in queries/Shop*Queries.lua.
local ShopCart = Model:extend("shop_carts", { timestamp = true })

return ShopCart
