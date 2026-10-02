local Model = require("lapis.db.model").Model

-- Thin model for shop_stock_reservations (Workstation AI Shop). Business logic lives in queries/Shop*Queries.lua.
local ShopStockReservation = Model:extend("shop_stock_reservations", { timestamp = true })

return ShopStockReservation
