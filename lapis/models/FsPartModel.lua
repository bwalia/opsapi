local Model = require("lapis.db.model").Model
local FsParts = Model:extend("fs_parts", { timestamp = true })
return FsParts
