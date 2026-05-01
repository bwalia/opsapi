local Model = require("lapis.db.model").Model
local CrmActivities = Model:extend("crm_activities", { timestamp = true })
return CrmActivities
