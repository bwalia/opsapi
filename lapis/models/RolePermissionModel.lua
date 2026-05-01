local Model = require("lapis.db.model").Model

local UserRoles = Model:extend("role__permissions", {
    timestamp = true,
})

return UserRoles