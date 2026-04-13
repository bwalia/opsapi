local Model = require("lapis.db.model").Model

local Projects = Model:extend("projects", {
    timestamp = true,
    has_many = {
        { "templates", "TemplateModel", through = "ProjectTemplateModel", key = "project_id" }
    }
})

return Projects