local Model = require("lapis.db.model").Model

local ChatReactionModel = Model:extend("chat_message_reactions", {
    timestamp = false,
    relations = {
        { "message", belongs_to = "ChatMessageModel", key = "message_uuid", local_key = "uuid" }
    }
})

return ChatReactionModel
