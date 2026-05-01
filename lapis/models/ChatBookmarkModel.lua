local Model = require("lapis.db.model").Model

local ChatBookmarkModel = Model:extend("chat_bookmarks", {
    timestamp = false,
    relations = {
        { "message", belongs_to = "ChatMessageModel", key = "message_uuid", local_key = "uuid" }
    }
})

return ChatBookmarkModel
