local Model = require("lapis.db.model").Model

local ChatFileAttachmentModel = Model:extend("chat_file_attachments", {
    timestamp = true,
    relations = {
        { "message", belongs_to = "ChatMessageModel", key = "message_uuid", local_key = "uuid" },
        { "channel", belongs_to = "ChatChannelModel", key = "channel_uuid", local_key = "uuid" }
    }
})

return ChatFileAttachmentModel
