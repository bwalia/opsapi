local Model = require("lapis.db.model").Model

local Roles = Model:extend("roles", {
    timestamp = true,
    has_many = {
        { "users", "UserModel", through = "UserRoleModel", key = "role_id" }
    }
})

return Roles
