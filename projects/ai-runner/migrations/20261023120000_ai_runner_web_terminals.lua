-- Web terminals per workspace (docs/AI_RUNNER_WEB_TERMINAL.md): address, sealed shared secret, the agents people may
-- pick; launches record the folder, agent and outcome.
return function(schema, db)
    db.query([[
        CREATE TABLE IF NOT EXISTS ar_terminals (
            id BIGSERIAL PRIMARY KEY,
            uuid UUID NOT NULL UNIQUE DEFAULT gen_random_uuid(),
            namespace_id INTEGER NOT NULL REFERENCES namespaces(id) ON DELETE CASCADE,
            name VARCHAR(100) NOT NULL,
            url TEXT NOT NULL,
            secret_sealed TEXT NOT NULL,
            secret_hint VARCHAR(16),
            agents JSONB NOT NULL DEFAULT '[]',
            is_active BOOLEAN NOT NULL DEFAULT TRUE,
            created_by VARCHAR(255),
            created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
            updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
        )
    ]])
    db.query("CREATE INDEX IF NOT EXISTS ar_terminals_ns_idx ON ar_terminals (namespace_id, is_active)")

    db.query([[
        ALTER TABLE ar_terminal_sessions
            ADD COLUMN IF NOT EXISTS terminal_uuid UUID,
            ADD COLUMN IF NOT EXISTS path TEXT,
            ADD COLUMN IF NOT EXISTS agent VARCHAR(32),
            ADD COLUMN IF NOT EXISTS agent_label VARCHAR(60),
            ADD COLUMN IF NOT EXISTS terminal_user VARCHAR(64),
            ADD COLUMN IF NOT EXISTS expires_at TIMESTAMPTZ,
            ADD COLUMN IF NOT EXISTS exit_code INTEGER,
            ADD COLUMN IF NOT EXISTS ended_reason TEXT,
            ADD COLUMN IF NOT EXISTS last_event_at TIMESTAMPTZ
    ]])
    db.query([[CREATE INDEX IF NOT EXISTS ar_terminal_sessions_paths_idx
        ON ar_terminal_sessions (namespace_id, project_uuid, terminal_uuid, created_at DESC)]])
end
