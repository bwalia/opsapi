local Model = require("lapis.db.model").Model
local M = Model:extend("fs_contracts", { timestamp = true })
return M
