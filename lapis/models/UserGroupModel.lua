local Model = require("lapis.db.model").Model

local UserGroups = Model:extend("user__groups", {
    timestamp = true,
})

return UserGroups