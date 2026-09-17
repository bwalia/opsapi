local Model = require("lapis.db.model").Model
local M = Model:extend("fs_contacts", { timestamp = true })
return M
