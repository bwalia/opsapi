local Model = require("lapis.db.model").Model

local ChatChannelInviteModel = Model:extend("chat_channel_invites", {
    timestamp = true,
    relations = {
        { "channel", belongs_to = "ChatChannelModel", key = "channel_uuid", local_key = "uuid" }
    }
})

return ChatChannelInviteModel
