local Model = require("lapis.db.model").Model
local CrmDeals = Model:extend("crm_deals", { timestamp = true })
return CrmDeals
