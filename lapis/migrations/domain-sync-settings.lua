--[[
    Domain Sync Settings
    ====================

    ONE persisted target per namespace so the Domains module remembers where to
    sync (repo + branch) and which GitHub authentication to use — configure once,
    then "Sync to Repo" / "Run Pipeline" just work with no re-entry.

    The GitHub token is NOT stored here — this row references a Services-module
    GitHub integration (namespace_github_integrations) by id; that integration
    holds the encrypted PAT. Keeps a single source of truth for credentials.

    Gated on FEATURES.SERVICES.
]]

local db = require("lapis.db")

local function table_exists(name)
    local r = db.query("SELECT to_regclass('public.' || ?) IS NOT NULL AS ok", name)
    return r and r[1] and r[1].ok
end

return {
    [1] = function()
        if table_exists("domain_sync_settings") then return end

        db.query([[
            CREATE TABLE IF NOT EXISTS domain_sync_settings (
                id BIGSERIAL PRIMARY KEY,
                uuid TEXT UNIQUE NOT NULL,
                namespace_id BIGINT NOT NULL REFERENCES namespaces(id) ON DELETE CASCADE,

                -- Target repo (owner/repo) + branch to commit the vhosts/manifest to
                owner TEXT,
                repo TEXT,
                branch TEXT DEFAULT 'main',

                -- Which Services GitHub integration (encrypted PAT) authenticates
                github_integration_id TEXT,

                -- Optional overrides
                data_base TEXT,          -- server-files root (default .github/wslproxy/data)
                default_environment TEXT DEFAULT 'prod',

                created_at TIMESTAMP DEFAULT NOW(),
                updated_at TIMESTAMP DEFAULT NOW(),

                -- Exactly one settings row per namespace
                CONSTRAINT domain_sync_settings_namespace_unique UNIQUE (namespace_id)
            )
        ]])

        pcall(function() db.query([[CREATE INDEX domain_sync_settings_namespace_idx ON domain_sync_settings (namespace_id)]]) end)
    end,

    -- [2] Template-driven wslproxy rendering + rule generation (see
    -- helper/wslproxy-server.lua). All nullable — NULL means "use the built-in
    -- default template", so this is fully backward-compatible.
    [2] = function()
        if not table_exists("domain_sync_settings") then return end
        local function add(sql) pcall(function() db.query(sql) end) end
        -- Override JSON templates ({{placeholder}} strings). NULL -> code default.
        add([[ALTER TABLE domain_sync_settings ADD COLUMN IF NOT EXISTS server_template TEXT]])
        add([[ALTER TABLE domain_sync_settings ADD COLUMN IF NOT EXISTS rule_template TEXT]])
        -- Fallbacks when a domain row leaves wslproxy_rule_id / proxy_target blank.
        add([[ALTER TABLE domain_sync_settings ADD COLUMN IF NOT EXISTS default_rule_id TEXT]])
        add([[ALTER TABLE domain_sync_settings ADD COLUMN IF NOT EXISTS default_backend TEXT]])
        -- Whether the sync also emits rule files (default on).
        add([[ALTER TABLE domain_sync_settings ADD COLUMN IF NOT EXISTS sync_rules BOOLEAN DEFAULT TRUE]])
    end,
}
