local Model = require("lapis.db.model").Model

-- Thin model for shop_quotes (Workstation AI Shop). Business logic lives in queries/Shop*Queries.lua.
local ShopQuote = Model:extend("shop_quotes", { timestamp = true })

return ShopQuote
