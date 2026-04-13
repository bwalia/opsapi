local Model = require("lapis.db.model").Model

local ChatDraftModel = Model:extend("chat_drafts", {
    timestamp = true,
    relations = {
        { "channel", belongs_to = "ChatChannelModel", key = "channel_uuid", local_key = "uuid" }
    }
})

return ChatDraftModel
