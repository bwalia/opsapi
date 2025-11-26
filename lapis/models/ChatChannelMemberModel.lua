local Model = require("lapis.db.model").Model

local ChatChannelMemberModel = Model:extend("chat_channel_members", {
    timestamp = true,
    relations = {
        { "channel", belongs_to = "ChatChannelModel", key = "channel_uuid", local_key = "uuid" }
    }
})

return ChatChannelMemberModel
