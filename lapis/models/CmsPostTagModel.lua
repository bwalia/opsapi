local Model = require("lapis.db.model").Model

-- Join row between a blog post and a tag. No `updated_at` on this table, so
-- `timestamp` is left off (the model would try to set a column that isn't there).
local CmsPostTag = Model:extend("cms_post_tags", {
    relations = {
        { "post", belongs_to = "CmsPostModel", key = "post_id" },
        { "tag",  belongs_to = "CmsTagModel", key = "tag_id" },
    }
})

return CmsPostTag
