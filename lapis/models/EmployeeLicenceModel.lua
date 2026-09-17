local Model = require("lapis.db.model").Model
local M = Model:extend("employee_licences", { timestamp = true })
return M
