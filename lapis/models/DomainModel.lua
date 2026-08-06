local Model = require("lapis.db.model").Model
local Domains = Model:extend("domains", { timestamp = true })
return Domains
