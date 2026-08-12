local Model = require("lapis.db.model").Model

local CmsPost = Model:extend("cms_posts", {
    timestamp = true,
    relations = {
        { "namespace", belongs_to = "NamespaceModel", key = "namespace_id" },
        { "category",  belongs_to = "CmsCategoryModel", key = "category_id" },
    }
})

return CmsPost
