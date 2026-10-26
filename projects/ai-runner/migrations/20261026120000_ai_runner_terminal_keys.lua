-- Web terminal keys managed in OpsAPI (docs/AI_RUNNER_WEB_TERMINAL.md §10): a manager issues each person a key for
-- a terminal (only the public half is kept), blocks it, and it expires after 90 days. The terminal fetches the list.
return function(schema, db)
    db.query([[
        CREATE TABLE IF NOT EXISTS ar_terminal_keys (
            id SERIAL PRIMARY KEY,
            uuid VARCHAR(36) NOT NULL UNIQUE DEFAULT gen_random_uuid()::text,
            namespace_id INTEGER NOT NULL REFERENCES namespaces(id) ON DELETE CASCADE,
            terminal_id INTEGER NOT NULL REFERENCES ar_terminals(id) ON DELETE CASCADE,
            user_uuid VARCHAR(255) NOT NULL,
            terminal_user VARCHAR(32) NOT NULL,
            public_key TEXT NOT NULL,
            fingerprint VARCHAR(64) NOT NULL,
            created_by VARCHAR(255),
            created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
            expires_at TIMESTAMPTZ NOT NULL,
            reminded_at TIMESTAMPTZ,
            revoked_at TIMESTAMPTZ,
            revoked_by VARCHAR(255),
            revoked_reason TEXT
        )
    ]])
    db.query([[CREATE UNIQUE INDEX IF NOT EXISTS ar_terminal_keys_fingerprint_idx
        ON ar_terminal_keys (terminal_id, fingerprint)]])
    -- One live key per person per terminal: issuing a new one blocks the old one.
    db.query([[CREATE UNIQUE INDEX IF NOT EXISTS ar_terminal_keys_one_live_idx
        ON ar_terminal_keys (terminal_id, user_uuid) WHERE revoked_at IS NULL]])
    db.query([[CREATE INDEX IF NOT EXISTS ar_terminal_keys_user_idx ON ar_terminal_keys (namespace_id, user_uuid)]])
end
