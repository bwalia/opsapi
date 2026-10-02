local Model = require("lapis.db.model").Model

-- Thin model for shop_rules (Workstation AI Shop). Business logic lives in queries/Shop*Queries.lua.
local ShopRule = Model:extend("shop_rules", { timestamp = true })

return ShopRule
