local Model = require("lapis.db.model").Model

local NamespaceServices = Model:extend("namespace_services", {
    timestamp = true,
})

return NamespaceServices
