local Model = require("lapis.db.model").Model

-- Customer site (field service). A saved address a customer's jobs recur at.
local FsSiteModel = Model:extend("fs_sites", { timestamp = true })

return FsSiteModel
