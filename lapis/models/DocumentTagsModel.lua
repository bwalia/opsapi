local Model = require("lapis.db.model").Model

local DocumentTags = Model:extend("document__tags", {
    timestamp = true,
})

return DocumentTags
