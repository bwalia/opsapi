--[[
    Domain sync repositories (multi-repo)
    =====================================

    Named GitHub repos a namespace can sync domains to. The single
    domain_sync_settings row is the DEFAULT repo; this table holds the ADDITIONAL
    ones. Each domain is assigned to a repo (domains.sync_repo_uuid); at sync the
    domains are grouped by their assigned repo and one PR is opened per repo,
    each authenticated with that repo's own GitHub integration.

    See queries/DomainSyncRepoQueries.lua and routes/domains.lua. Gated on
    FEATURES.SERVICES. Idempotent.
]]

local db = require("lapis.db")

return {
    [1] = function()
        pcall(function()
            db.query([[
                CREATE TABLE IF NOT EXISTS domain_sync_repos (
                    id                     SERIAL PRIMARY KEY,
                    uuid                   TEXT UNIQUE,
                    namespace_id           INTEGER NOT NULL,
                    name                   TEXT,
                    owner                  TEXT NOT NULL,
                    repo                   TEXT NOT NULL,
                    branch                 TEXT DEFAULT 'main',
                    github_integration_id  TEXT,
                    created_at             TIMESTAMPTZ DEFAULT NOW(),
                    updated_at             TIMESTAMPTZ DEFAULT NOW(),
                    UNIQUE (namespace_id, owner, repo, branch)
                )
            ]])
        end)
        pcall(function()
            db.query([[CREATE INDEX IF NOT EXISTS domain_sync_repos_ns_idx
                       ON domain_sync_repos (namespace_id)]])
        end)
    end,
}
