local Model = require("lapis.db.model").Model

local VaultExternalProviders = Model:extend("vault_external_providers", {
    timestamp = true,
})

return VaultExternalProviders
