local Model = require("lapis.db.model").Model

local NamespaceServiceSecrets = Model:extend("namespace_service_secrets", {
    timestamp = true,
})

return NamespaceServiceSecrets
