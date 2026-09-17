local Model = require("lapis.db.model").Model
local M = Model:extend("fs_assets", { timestamp = true })
return M
