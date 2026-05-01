local Model = require("lapis.db.model").Model

local ProjectTemplate = Model:extend("project__templates", {
    timestamp = true,
})

return ProjectTemplate