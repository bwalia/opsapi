local Model = require("lapis.db.model").Model
local FsJobs = Model:extend("fs_jobs", { timestamp = true })
return FsJobs
