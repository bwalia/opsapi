local Model = require("lapis.db.model").Model

local ChatMentionModel = Model:extend("chat_mentions", {
    timestamp = false,
    relations = {
        { "message", belongs_to = "ChatMessageModel", key = "message_uuid", local_key = "uuid" },
        { "channel", belongs_to = "ChatChannelModel", key = "channel_uuid", local_key = "uuid" }
    }
})

return ChatMentionModel
