local Model = require("lapis.db.model").Model

-- updated_at is maintained by the DB trigger theme_touch_updated_at.
-- No created_at column on this table, so disable Lapis auto-timestamping.
local ThemeTokens = Model:extend("theme_tokens", {
    timestamp = false,
    primary_key = "id",
})

return ThemeTokens
