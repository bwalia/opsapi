local Model = require("lapis.db.model").Model
local FsSites = Model:extend("fs_sites", { timestamp = true })
return FsSites
