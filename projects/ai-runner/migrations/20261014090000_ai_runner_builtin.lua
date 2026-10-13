-- AI Runs: the built-in runner (docs/AI_RUNNER.md §28). Each workspace gets one connection of kind 'builtin' that
-- runs inside OpsAPI on its AI models (the platform's, or the workspace's own), and the GitHub App installations a
-- workspace connected, whose repositories the built-in runner works in. Idempotent: safe to re-run on a restored
-- database.
return function(schema, db)
    db.query("ALTER TABLE ar_runners DROP CONSTRAINT IF EXISTS ar_runners_kind_check")
    db.query([[ALTER TABLE ar_runners ADD CONSTRAINT ar_runners_kind_check
        CHECK (kind IN ('runner', 'source', 'builtin'))]])
    -- One built-in runner per workspace, created when the workspace first needs it.
    db.query([[CREATE UNIQUE INDEX IF NOT EXISTS ar_runners_one_builtin ON ar_runners (namespace_id)
        WHERE kind = 'builtin']])

    -- §28.3: a GitHub App installation (an account's or organisation's) this workspace connected, after GitHub
    -- confirmed the person connecting it can reach it. The same installation may serve several workspaces.
    db.query([[
        CREATE TABLE IF NOT EXISTS ar_github_installations (
            id BIGSERIAL PRIMARY KEY,
            uuid UUID NOT NULL UNIQUE DEFAULT gen_random_uuid(),
            namespace_id INTEGER NOT NULL REFERENCES namespaces(id) ON DELETE CASCADE,
            installation_id BIGINT NOT NULL,
            account_login VARCHAR(255),
            account_type VARCHAR(40),
            repository_selection VARCHAR(20),
            created_by VARCHAR(255),
            created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
            updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
            UNIQUE (namespace_id, installation_id)
        )
    ]])
end
