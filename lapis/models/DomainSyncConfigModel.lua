local Model = require("lapis.db.model").Model
local DomainSyncConfigs = Model:extend("domain_sync_configs", { timestamp = true })
return DomainSyncConfigs
