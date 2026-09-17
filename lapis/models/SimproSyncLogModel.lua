local Model = require("lapis.db.model").Model
-- Append-only: rows are never updated, so there is no updated_at to maintain.
local M = Model:extend("simpro_sync_log")
return M
