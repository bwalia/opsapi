local Model = require("lapis.db.model").Model

local CmsCategory = Model:extend("cms_categories", {
    timestamp = true,
    relations = {
        { "namespace", belongs_to = "NamespaceModel", key = "namespace_id" },
        { "parent",    belongs_to = "CmsCategoryModel", key = "parent_id" },
        { "posts",     has_many = "CmsPostModel", key = "category_id" },
    }
})

return CmsCategory
