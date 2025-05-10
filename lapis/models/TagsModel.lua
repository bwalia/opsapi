local Model = require("lapis.db.model").Model

local Tags = Model:extend("tags", {
    timestamp = true,
    relations = {
        {"documents", has_many = "DocumentTagsModel", key = "user_id"}
    }
})

return Tags