-- Web terminal sessions linked to kanban tasks + PR poll bookkeeping.
return function(schema, db)
    db.query([[
        CREATE TABLE IF NOT EXISTS ar_terminal_sessions (
            id BIGSERIAL PRIMARY KEY,
            uuid UUID NOT NULL UNIQUE DEFAULT gen_random_uuid(),
            namespace_id INTEGER NOT NULL REFERENCES namespaces(id) ON DELETE CASCADE,
            task_uuid VARCHAR(255) NOT NULL,
            project_uuid VARCHAR(255) NOT NULL,
            opened_by VARCHAR(255),
            terminal_url TEXT NOT NULL,
            session_id VARCHAR(64),
            repo_url TEXT,
            status VARCHAR(40) NOT NULL DEFAULT 'launched',
            started_at TIMESTAMPTZ,
            ended_at TIMESTAMPTZ,
            created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
            updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
        )
    ]])
    db.query([[CREATE INDEX IF NOT EXISTS ar_terminal_sessions_task_idx
        ON ar_terminal_sessions (namespace_id, task_uuid, created_at DESC)]])
    db.query([[CREATE INDEX IF NOT EXISTS ar_terminal_sessions_session_idx
        ON ar_terminal_sessions (session_id) WHERE session_id IS NOT NULL]])

    db.query([[
        ALTER TABLE ar_task_prs
            ADD COLUMN IF NOT EXISTS github_state_checked_at TIMESTAMPTZ
    ]])
end
