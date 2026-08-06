--[[
    Domain Pipeline Runs
    ====================

    Tracks an opsapi-driven "domain pipeline": sync domains → repo, then dispatch
    a chain of GitHub workflows in order (cloudflare-dns-reconcile →
    wslproxy-register-domains → auto-tag-main), waiting for each before the next.

    The orchestration runs in an ngx.timer (background), updating this row so the
    dashboard can poll progress. See helper/domain-pipeline.lua. Gated SERVICES.
]]

local db = require("lapis.db")

local function table_exists(name)
    local r = db.query("SELECT to_regclass('public.' || ?) IS NOT NULL AS ok", name)
    return r and r[1] and r[1].ok
end

return {
    [1] = function()
        if table_exists("domain_pipeline_runs") then return end

        db.query([[
            CREATE TABLE IF NOT EXISTS domain_pipeline_runs (
                id BIGSERIAL PRIMARY KEY,
                uuid TEXT UNIQUE NOT NULL,
                namespace_id BIGINT NOT NULL REFERENCES namespaces(id) ON DELETE CASCADE,

                status TEXT NOT NULL DEFAULT 'pending',   -- pending|running|success|failed
                environment TEXT DEFAULT 'prod',
                owner TEXT,
                repo TEXT,
                branch TEXT DEFAULT 'main',
                github_integration_id TEXT,

                commit_sha TEXT,                          -- from the sync step
                current_step INTEGER DEFAULT 0,
                steps JSONB DEFAULT '[]',                 -- [{name,workflow,status,run_id,run_url,conclusion,error,...}]
                error TEXT,

                triggered_by_uuid TEXT,
                started_at TIMESTAMP,
                finished_at TIMESTAMP,
                created_at TIMESTAMP DEFAULT NOW(),
                updated_at TIMESTAMP DEFAULT NOW()
            )
        ]])

        pcall(function() db.query([[CREATE INDEX domain_pipeline_runs_ns_idx ON domain_pipeline_runs (namespace_id, created_at DESC)]]) end)
        pcall(function() db.query([[CREATE INDEX domain_pipeline_runs_uuid_idx ON domain_pipeline_runs (uuid)]]) end)
    end,
}
