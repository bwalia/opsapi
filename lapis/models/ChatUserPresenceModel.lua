local Model = require("lapis.db.model").Model

local ChatUserPresenceModel = Model:extend("chat_user_presence", {
    timestamp = true
})

return ChatUserPresenceModel
