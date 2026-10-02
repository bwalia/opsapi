local Model = require("lapis.db.model").Model

-- Thin model for shop_options (Workstation AI Shop). Business logic lives in queries/Shop*Queries.lua.
local ShopOption = Model:extend("shop_options", { timestamp = true })

return ShopOption
