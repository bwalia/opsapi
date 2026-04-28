local Model = require("lapis.db.model").Model

-- Composite primary key (namespace_id, project_code); no surrogate id.
local NamespaceActiveTheme = Model:extend("namespace_active_themes", {
    timestamp = false,
    primary_key = { "namespace_id", "project_code" },
})

return NamespaceActiveTheme
