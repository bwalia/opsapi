local Model = require("lapis.db.model").Model
local Employees = Model:extend("employees", { timestamp = true })
return Employees
