local Model = require("lapis.db.model").Model

local PermissionModel = Model:extend("permissions", {
    timestamp = true,
    relations = {
        {"module", belongs_to = "ModuleModel"}
    }
})

return PermissionModel
