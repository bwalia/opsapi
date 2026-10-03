local Model = require("lapis.db.model").Model

-- Thin model for shop_market_sources (shop market-price RAG).
-- Business logic lives in queries/ShopMarketQueries.lua.
local ShopMarketSource = Model:extend("shop_market_sources", { timestamp = true })

return ShopMarketSource
