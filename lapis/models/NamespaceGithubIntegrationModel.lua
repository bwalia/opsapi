local Model = require("lapis.db.model").Model

local NamespaceGithubIntegrations = Model:extend("namespace_github_integrations", {
    timestamp = true,
})

return NamespaceGithubIntegrations
