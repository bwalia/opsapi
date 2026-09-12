local Model = require("lapis.db.model").Model
local FsJobItems = Model:extend("fs_job_items", { timestamp = true })
return FsJobItems
