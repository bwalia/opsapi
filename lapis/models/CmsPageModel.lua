local Model = require("lapis.db.model").Model

local CmsPage = Model:extend("cms_pages", {
    timestamp = true,
    relations = {
        { "namespace", belongs_to = "NamespaceModel", key = "namespace_id" },
        { "parent",    belongs_to = "CmsPageModel", key = "parent_id" },
    }
})

return CmsPage
