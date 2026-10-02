local Model = require("lapis.db.model").Model

-- Thin model for shop_categories (Workstation AI Shop). Business logic lives in queries/Shop*Queries.lua.
local ShopCategory = Model:extend("shop_categories", { timestamp = true })

return ShopCategory
