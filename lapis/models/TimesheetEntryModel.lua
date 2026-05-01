local Model = require("lapis.db.model").Model
local TimesheetEntries = Model:extend("timesheet_entries", { timestamp = true })
return TimesheetEntries
