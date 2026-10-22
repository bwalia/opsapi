--[[
  Conversational Tax Agent — session storage

  Backs the "file my tax by chatting" agent (routes/tax-agent, lib/agent/tax-tools).
  Only executed when PROJECT_CODE includes 'tax_copilot'.

  Tables:
  - tax_agent_sessions : one resumable chat per user+tax_year (profile, progress,
                         and the single pending confirm awaiting the user's OK)
  - tax_agent_messages : the turn-by-turn transcript (text + structured cards)

  Both are scoped by namespace_id + user_id; every query in TaxAgentQueries filters
  on both, and the route runs behind requireAuth + requireNamespace. Soft FKs
  (app-enforced), consistent with the rest of the tax_* schema.
]]

local schema = require("lapis.db.schema")
local types = schema.types
local db = require("lapis.db")

return {
    -- 1. Sessions + messages + indexes (one step — brand-new tables).
    [1] = function()
        schema.create_table("tax_agent_sessions", {
            { "id",                  types.serial },
            { "uuid",                types.varchar({ unique = true }) },
            { "namespace_id",        types.integer },
            { "user_id",             types.integer },
            { "tax_year",            types.varchar },
            { "status",              types.varchar({ default = "'active'" }) },
            { "current_context",     types.varchar({ null = true }) },
            { "current_entity_uuid", types.varchar({ null = true }) },
            { "archived",            types.boolean({ default = false }) },
            "income_types jsonb NOT NULL DEFAULT '[]'::jsonb",
            "profile jsonb NOT NULL DEFAULT '{}'::jsonb",
            "progress jsonb NOT NULL DEFAULT '{}'::jsonb",
            "pending jsonb",
            { "created_at",          types.time({ default = db.raw("NOW()") }) },
            { "updated_at",          types.time({ default = db.raw("NOW()") }) },
            "PRIMARY KEY (id)",
        })
        db.query([[CREATE INDEX IF NOT EXISTS idx_tax_agent_sessions_scope
            ON tax_agent_sessions (namespace_id, user_id, tax_year)]])
        db.query([[CREATE INDEX IF NOT EXISTS idx_tax_agent_sessions_active
            ON tax_agent_sessions (user_id, status) WHERE NOT archived]])

        schema.create_table("tax_agent_messages", {
            { "id",                  types.serial },
            { "uuid",                types.varchar({ unique = true }) },
            { "session_id",          types.integer },
            { "namespace_id",        types.integer },
            { "user_id",             types.integer },
            { "role",                types.varchar }, -- user | assistant
            "content text",
            "confirm_card jsonb",
            { "confirm_disposition", types.varchar({ null = true }) }, -- saved | changed
            "statement_job jsonb",
            "upload_prompt jsonb",
            "quick_replies jsonb",
            { "created_at",          types.time({ default = db.raw("NOW()") }) },
            "PRIMARY KEY (id)",
        })
        db.query([[CREATE INDEX IF NOT EXISTS idx_tax_agent_messages_session
            ON tax_agent_messages (session_id, id)]])
        db.query([[CREATE INDEX IF NOT EXISTS idx_tax_agent_messages_scope
            ON tax_agent_messages (namespace_id, user_id)]])
    end,
}
