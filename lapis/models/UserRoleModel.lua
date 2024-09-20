local Model = require("lapis.db.model").Model

local UserRoles = Model:extend("user__roles", {
    timestamp = true,
    primary_key = "id"
})

return UserRoles