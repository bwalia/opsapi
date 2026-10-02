local Model = require("lapis.db.model").Model

-- Thin model for shop_stock_movements (Workstation AI Shop). Business logic lives in queries/Shop*Queries.lua.
local ShopStockMovement = Model:extend("shop_stock_movements", { timestamp = true })

return ShopStockMovement
