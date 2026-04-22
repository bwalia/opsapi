local Model = require("lapis.db.model").Model

local Theme = Model:extend("themes", {
    timestamp = true,
    primary_key = "id",
})

return Theme
