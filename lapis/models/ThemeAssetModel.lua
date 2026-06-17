local Model = require("lapis.db.model").Model

local ThemeAsset = Model:extend("theme_assets", {
    timestamp = false,
    primary_key = "id",
})

return ThemeAsset
