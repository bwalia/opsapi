local Model = require("lapis.db.model").Model

local Projects = Model:extend("projects", {
    timestamp = true,
    relations = {
        {"templates", has_many = "ProjectTemplateModel", key = "project_id"}
    }
})

return Projects