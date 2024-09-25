local Model = require("lapis.db.model").Model

local Module = Model:extend("modules", {
    timestamp = true,
})

return Module
