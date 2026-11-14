--[[
    tax_statements.processing_job (jsonb, nullable): what the background worker in
    routes/tax-process.lua needs to pick a statement up again after a restart, i.e.
    the File My Tax chat it came from and the classifier profile to use:
        { "session_id": 42, "profile_type": "landlord" }
    No credentials are stored; a resumed job runs as the user whose poll resumed it.
    Idempotent (ADD COLUMN IF NOT EXISTS).
]]

local db = require("lapis.db")

return {
    [1] = function()
        db.query("ALTER TABLE tax_statements ADD COLUMN IF NOT EXISTS processing_job jsonb")
    end,
}
