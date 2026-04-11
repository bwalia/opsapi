local Model = require("lapis.db.model").Model
local CrmPipelines = Model:extend("crm_pipelines", { timestamp = true })
return CrmPipelines
