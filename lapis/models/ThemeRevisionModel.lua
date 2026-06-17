local Model = require("lapis.db.model").Model

-- Append-only; no updated_at. Lapis auto-timestamping disabled to avoid
-- attempts to write to a non-existent updated_at column.
local ThemeRevision = Model:extend("theme_revisions", {
    timestamp = false,
    primary_key = "id",
})

return ThemeRevision
