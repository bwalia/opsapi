local Model = require("lapis.db.model").Model

-- Thin model for shop_option_groups (Workstation AI Shop). Business logic lives in queries/Shop*Queries.lua.
local ShopOptionGroup = Model:extend("shop_option_groups", { timestamp = true })

return ShopOptionGroup
