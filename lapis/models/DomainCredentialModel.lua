local Model = require("lapis.db.model").Model
local DomainCredentials = Model:extend("domain_credentials", { timestamp = true })
return DomainCredentials
