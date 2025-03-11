local Model = require("lapis.db.model").Model

local Templates = Model:extend("templates", {
    timestamp = true,
    relations = {
        {"projects", has_many = "ProjectTemplateModel", key = "template_id"}
    }
})

return Templates
