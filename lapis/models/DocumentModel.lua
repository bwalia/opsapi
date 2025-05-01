local Model = require("lapis.db.model").Model

local Document = Model:extend("documents", {
    timestamp = true,
    relations = {
        {"user", belongs_to = "Users", key = "user_id"}
      }
})

return Document
