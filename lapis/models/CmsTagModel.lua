local Model = require("lapis.db.model").Model

local CmsTag = Model:extend("cms_tags", {
    timestamp = true,
    relations = {
        { "namespace", belongs_to = "NamespaceModel", key = "namespace_id" },
    }
})

return CmsTag
