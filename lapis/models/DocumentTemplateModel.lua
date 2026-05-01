local Model = require("lapis.db.model").Model

local DocumentTemplates = Model:extend("document_templates", {
    timestamp = true
})

return DocumentTemplates
