local Model = require("lapis.db.model").Model
local M = Model:extend("fs_quotes", { timestamp = true })
return M
