local Model = require("lapis.db.model").Model

local Users = Model:extend("users", {
    timestamp = true,
    relations = {
        {"roles", has_many = "UserRoleModel", key = "user_id"}
    }
})

return Users