local Model = require("lapis.db.model").Model
local M = Model:extend("fs_asset_test_history", { timestamp = true })
return M
