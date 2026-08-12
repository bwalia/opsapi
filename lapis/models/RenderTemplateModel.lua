local Model = require("lapis.db.model").Model

local RenderTemplate = Model:extend("render_templates", {
    timestamp = true,
    relations = {
        { "namespace", belongs_to = "NamespaceModel", key = "namespace_id" },
    }
})

return RenderTemplate
