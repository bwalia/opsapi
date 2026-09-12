local Model = require("lapis.db.model").Model
local FsJobPhases = Model:extend("fs_job_phases", { timestamp = true })
return FsJobPhases
