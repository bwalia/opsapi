local Model = require("lapis.db.model").Model
local DomainSyncSettings = Model:extend("domain_sync_settings", { timestamp = true })
return DomainSyncSettings
