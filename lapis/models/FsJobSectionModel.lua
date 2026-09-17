local Model = require("lapis.db.model").Model
local M = Model:extend("fs_job_sections", { timestamp = true })
return M
