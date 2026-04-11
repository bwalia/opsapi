local Model = require("lapis.db.model").Model
local CrmAccounts = Model:extend("crm_accounts", { timestamp = true })
return CrmAccounts
