local Model = require("lapis.db.model").Model
local DomainPipelineRuns = Model:extend("domain_pipeline_runs", { timestamp = true })
return DomainPipelineRuns
