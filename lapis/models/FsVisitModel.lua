local Model = require("lapis.db.model").Model
local FsVisits = Model:extend("fs_visits", { timestamp = true })
return FsVisits
