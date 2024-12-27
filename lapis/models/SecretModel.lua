local Model = require("lapis.db.model").Model

local Secrets = Model:extend("secrets", {
    timestamp = true,
})

return Secrets
