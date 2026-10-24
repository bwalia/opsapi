-- Web terminal auto sign-in for power users and agents reporting their pull request (docs/AI_RUNNER_WEB_TERMINAL.md
-- §8, §9): a terminal opts in, a person's emailed-code step-up is remembered for a while, each launch has a report
-- token (only its hash is kept), and pull requests reported from a terminal are attached once per URL.
return function(schema, db)
    db.query("ALTER TABLE ar_terminals ADD COLUMN IF NOT EXISTS autologin BOOLEAN NOT NULL DEFAULT FALSE")

    db.query([[
        CREATE TABLE IF NOT EXISTS ar_terminal_stepups (
            namespace_id INTEGER NOT NULL REFERENCES namespaces(id) ON DELETE CASCADE,
            user_uuid VARCHAR(255) NOT NULL,
            email TEXT NOT NULL,
            verified_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
            expires_at TIMESTAMPTZ NOT NULL,
            PRIMARY KEY (namespace_id, user_uuid)
        )
    ]])

    db.query([[
        ALTER TABLE ar_terminal_sessions
            ADD COLUMN IF NOT EXISTS autologin BOOLEAN NOT NULL DEFAULT FALSE,
            ADD COLUMN IF NOT EXISTS report_token_hash VARCHAR(64),
            ADD COLUMN IF NOT EXISTS reported_at TIMESTAMPTZ
    ]])
    db.query([[CREATE UNIQUE INDEX IF NOT EXISTS ar_terminal_sessions_report_idx
        ON ar_terminal_sessions (report_token_hash) WHERE report_token_hash IS NOT NULL]])

    db.query([[CREATE UNIQUE INDEX IF NOT EXISTS ar_task_prs_terminal_url_idx
        ON ar_task_prs (namespace_id, task_uuid, pr_url) WHERE run_uuid IS NULL]])
end
