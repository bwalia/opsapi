local Model = require("lapis.db.model").Model
local Timesheets = Model:extend("timesheets", { timestamp = true })
return Timesheets
