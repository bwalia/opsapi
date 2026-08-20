local Model = require("lapis.db.model").Model

local ApiKeys = Model:extend("api_keys", {
    timestamp = true,
})

return ApiKeys
