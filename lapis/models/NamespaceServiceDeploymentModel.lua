local Model = require("lapis.db.model").Model

local NamespaceServiceDeployments = Model:extend("namespace_service_deployments", {
    timestamp = true,
})

return NamespaceServiceDeployments
