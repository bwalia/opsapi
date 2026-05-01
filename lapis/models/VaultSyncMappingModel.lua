local Model = require("lapis.db.model").Model

local VaultSyncMappings = Model:extend("vault_sync_mappings", {
    timestamp = true,
})

return VaultSyncMappings
