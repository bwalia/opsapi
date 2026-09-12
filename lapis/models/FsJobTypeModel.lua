local Model = require("lapis.db.model").Model
local FsJobTypes = Model:extend("fs_job_types", { timestamp = true })
return FsJobTypes
