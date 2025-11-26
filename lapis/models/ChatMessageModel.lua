local Model = require("lapis.db.model").Model

local ChatMessageModel = Model:extend("chat_messages", {
    timestamp = true,
    relations = {
        { "channel", belongs_to = "ChatChannelModel", key = "channel_uuid", local_key = "uuid" },
        { "reactions", has_many = "ChatReactionModel", key = "message_uuid", local_key = "uuid" },
        { "replies", has_many = "ChatMessageModel", key = "parent_message_uuid", local_key = "uuid" }
    }
})

return ChatMessageModel
