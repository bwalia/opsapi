local Model = require("lapis.db.model").Model

local Groups = Model:extend("groups", {
    timestamp = true,
    relations = {
        {"members", has_many = "UserGroupModel", key = "user_id"}
    }
})

return Groups