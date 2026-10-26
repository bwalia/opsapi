-- Work log (docs/AI_RUNNER_WEB_TERMINAL.md §11): every web terminal tab, what the AI did in it (prompts, requests
-- with tokens and cost, tool actions) and a screen recording of it, sent by the terminal. Removing a terminal keeps
-- its work log (terminal_id becomes NULL); recordings still go after 30 days.
return function(schema, db)
    db.query([[
        CREATE TABLE IF NOT EXISTS ar_terminal_tabs (
            id SERIAL PRIMARY KEY,
            uuid VARCHAR(36) NOT NULL UNIQUE DEFAULT gen_random_uuid()::text,
            namespace_id INTEGER NOT NULL REFERENCES namespaces(id) ON DELETE CASCADE,
            terminal_id INTEGER REFERENCES ar_terminals(id) ON DELETE SET NULL,
            tab_id VARCHAR(64) NOT NULL,
            session_uuid VARCHAR(36),
            task_uuid VARCHAR(36),
            user_uuid VARCHAR(255),
            terminal_user VARCHAR(64),
            key_fingerprint VARCHAR(80),
            via VARCHAR(32),
            ip VARCHAR(64),
            kind VARCHAR(16),
            cwd TEXT,
            agent VARCHAR(64),
            opened_at TIMESTAMPTZ,
            closed_at TIMESTAMPTZ,
            end_reason TEXT,
            exit_code INTEGER,
            active_secs INTEGER NOT NULL DEFAULT 0,
            input_bytes BIGINT NOT NULL DEFAULT 0,
            output_bytes BIGINT NOT NULL DEFAULT 0,
            prompts INTEGER NOT NULL DEFAULT 0,
            requests INTEGER NOT NULL DEFAULT 0,
            tool_calls INTEGER NOT NULL DEFAULT 0,
            input_tokens BIGINT NOT NULL DEFAULT 0,
            output_tokens BIGINT NOT NULL DEFAULT 0,
            cache_read_tokens BIGINT NOT NULL DEFAULT 0,
            cache_write_tokens BIGINT NOT NULL DEFAULT 0,
            cost_usd NUMERIC(14, 6) NOT NULL DEFAULT 0,
            lines_added INTEGER NOT NULL DEFAULT 0,
            lines_removed INTEGER NOT NULL DEFAULT 0,
            commits INTEGER NOT NULL DEFAULT 0,
            pull_requests INTEGER NOT NULL DEFAULT 0,
            recording_parts INTEGER NOT NULL DEFAULT 0,
            recording_bytes BIGINT NOT NULL DEFAULT 0,
            created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
            updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
            UNIQUE (terminal_id, tab_id)
        )
    ]])
    db.query("CREATE INDEX IF NOT EXISTS ar_terminal_tabs_user_idx ON ar_terminal_tabs (namespace_id, user_uuid, opened_at)")
    db.query("CREATE INDEX IF NOT EXISTS ar_terminal_tabs_task_idx ON ar_terminal_tabs (namespace_id, task_uuid)")

    db.query([[
        CREATE TABLE IF NOT EXISTS ar_terminal_events (
            id BIGSERIAL PRIMARY KEY,
            namespace_id INTEGER NOT NULL REFERENCES namespaces(id) ON DELETE CASCADE,
            terminal_id INTEGER REFERENCES ar_terminals(id) ON DELETE SET NULL,
            tab_ref INTEGER REFERENCES ar_terminal_tabs(id) ON DELETE CASCADE,
            event_id VARCHAR(128) NOT NULL,
            at TIMESTAMPTZ NOT NULL,
            type VARCHAR(32) NOT NULL,
            claude_session VARCHAR(64),
            prompt_id VARCHAR(64),
            model VARCHAR(100),
            tool_name VARCHAR(100),
            success BOOLEAN,
            input_tokens INTEGER,
            output_tokens INTEGER,
            cache_read_tokens INTEGER,
            cache_write_tokens INTEGER,
            cost_usd NUMERIC(14, 6),
            duration_ms INTEGER,
            text TEXT,
            attrs JSONB NOT NULL DEFAULT '{}'::jsonb,
            created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
            UNIQUE (terminal_id, event_id)
        )
    ]])
    db.query("CREATE INDEX IF NOT EXISTS ar_terminal_events_tab_idx ON ar_terminal_events (tab_ref, at)")
    db.query("CREATE INDEX IF NOT EXISTS ar_terminal_events_text_idx ON ar_terminal_events (created_at) WHERE text IS NOT NULL")

    db.query([[
        CREATE TABLE IF NOT EXISTS ar_terminal_recordings (
            id SERIAL PRIMARY KEY,
            namespace_id INTEGER NOT NULL REFERENCES namespaces(id) ON DELETE CASCADE,
            tab_ref INTEGER NOT NULL REFERENCES ar_terminal_tabs(id) ON DELETE CASCADE,
            part INTEGER NOT NULL,
            final BOOLEAN NOT NULL DEFAULT FALSE,
            object_key TEXT NOT NULL,
            bucket TEXT NOT NULL,
            bytes INTEGER NOT NULL,
            created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
            UNIQUE (tab_ref, part)
        )
    ]])
end
