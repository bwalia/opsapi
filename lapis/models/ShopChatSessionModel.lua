local Model = require("lapis.db.model").Model

-- Thin model for shop_chat_sessions (Workstation AI Shop). Business logic lives in queries/Shop*Queries.lua.
local ShopChatSession = Model:extend("shop_chat_sessions", { timestamp = true })

return ShopChatSession
