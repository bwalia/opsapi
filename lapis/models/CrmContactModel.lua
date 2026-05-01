local Model = require("lapis.db.model").Model
local CrmContacts = Model:extend("crm_contacts", { timestamp = true })
return CrmContacts
