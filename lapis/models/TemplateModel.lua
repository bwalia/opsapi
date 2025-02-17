local Model = require("lapis.db.model").Model

local Templates = Model:extend("templates", {
    timestamp = true,
    has_many = {
        { "projects", "ProjectModel", through = "ProjectTemplateModel", key = "template_id" }
    }
})

return Templates
