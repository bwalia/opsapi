local Model = require("lapis.db.model").Model

local ChatReadReceiptModel = Model:extend("chat_read_receipts", {
    timestamp = true,
    relations = {
        { "channel", belongs_to = "ChatChannelModel", key = "channel_uuid", local_key = "uuid" }
    }
})

return ChatReadReceiptModel
