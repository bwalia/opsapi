local Model = require("lapis.db.model").Model

-- Thin model for shop_knowledge_chunks (Workstation AI Shop). Business logic lives in queries/Shop*Queries.lua.
local ShopKnowledgeChunk = Model:extend("shop_knowledge_chunks", { timestamp = true })

return ShopKnowledgeChunk
