local Model = require("lapis.db.model").Model

-- Thin model for shop_products (Workstation AI Shop). Business logic lives in queries/Shop*Queries.lua.
local ShopProduct = Model:extend("shop_products", { timestamp = true })

return ShopProduct
