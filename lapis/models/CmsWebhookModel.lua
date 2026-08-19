local Model = require("lapis.db.model").Model

local CmsWebhook = Model:extend("cms_webhooks", {
    timestamp = true,
    relations = {
        { "namespace", belongs_to = "NamespaceModel", key = "namespace_id" },
    }
})

return CmsWebhook
