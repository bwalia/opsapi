local Model = require("lapis.db.model").Model

local ThemeInstallation = Model:extend("theme_installations", {
    timestamp = false,
    primary_key = "id",
})

return ThemeInstallation
