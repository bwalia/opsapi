local Model = require("lapis.db.model").Model

-- Thin model for shop_market_observations (append-only: created_at, no updated_at).
-- Business logic lives in queries/ShopMarketQueries.lua.
local ShopMarketObservation = Model:extend("shop_market_observations")

return ShopMarketObservation
