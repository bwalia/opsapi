local Model = require("lapis.db.model").Model

local NamespaceServiceVariables = Model:extend("namespace_service_variables", {
    timestamp = true,
})

return NamespaceServiceVariables
