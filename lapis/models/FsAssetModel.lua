local Model = require("lapis.db.model").Model
local FsAssets = Model:extend("fs_assets", { timestamp = true })
return FsAssets
