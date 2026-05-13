local Model = require("lapis.db.model").Model
local CrmLeads = Model:extend("crm_leads", { timestamp = true })
return CrmLeads
