local Model = require("lapis.db.model").Model

-- Thin model for shop_cart_lines (Workstation AI Shop). Business logic lives in queries/Shop*Queries.lua.
local ShopCartLine = Model:extend("shop_cart_lines", { timestamp = true })

return ShopCartLine
