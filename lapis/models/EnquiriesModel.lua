local Model = require("lapis.db.model").Model

local Module = Model:extend("enquiries", {
    timestamp = true,
})

return Module
