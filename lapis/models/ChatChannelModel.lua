local Model = require("lapis.db.model").Model

local ChatChannelModel = Model:extend("chat_channels", {
    timestamp = true,
    relations = {
        { "members", has_many = "ChatChannelMemberModel", key = "channel_uuid", local_key = "uuid" },
        { "messages", has_many = "ChatMessageModel", key = "channel_uuid", local_key = "uuid" }
    }
})

return ChatChannelModel
