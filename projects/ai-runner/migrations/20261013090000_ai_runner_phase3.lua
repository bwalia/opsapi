-- AI Runs Phase 3 (docs/AI_RUNNER.md §23.1): start approval (pending_approval), the permission bridge, turns and
-- per-run usage totals, the run-scoped token. Idempotent: safe to re-run on a restored database.
return function(schema, db)
    -- pending_approval: open (one run per task, holds the folder lock) but not claimable.
    db.query("ALTER TABLE ar_runs DROP CONSTRAINT IF EXISTS ar_runs_status_check")
    db.query([[ALTER TABLE ar_runs ADD CONSTRAINT ar_runs_status_check CHECK (status IN ('pending_approval', 'queued',
        'claimed', 'starting', 'running', 'waiting_permission', 'needs_input', 'cancelling', 'succeeded', 'failed',
        'cancelled', 'lost'))]])
    db.query("DROP INDEX IF EXISTS ar_runs_one_open_per_task")
    db.query([[CREATE UNIQUE INDEX ar_runs_one_open_per_task ON ar_runs (task_uuid)
        WHERE status IN ('pending_approval', 'queued', 'claimed', 'starting', 'running', 'waiting_permission',
                         'needs_input', 'cancelling')]])
    db.query([[CREATE INDEX IF NOT EXISTS idx_ar_runs_pending_approval ON ar_runs (namespace_id, created_at)
        WHERE status = 'pending_approval']])

    for _, col in ipairs({
        "approved_by VARCHAR(255)",
        "approved_at TIMESTAMPTZ",
        "question TEXT",                           -- the open needs_input question
        "tokens_in BIGINT NOT NULL DEFAULT 0",
        "tokens_out BIGINT NOT NULL DEFAULT 0",
        "cache_read BIGINT NOT NULL DEFAULT 0",
        "cache_write BIGINT NOT NULL DEFAULT 0",
        "cost_estimate NUMERIC(12,4) NOT NULL DEFAULT 0",
        "turns INTEGER NOT NULL DEFAULT 0",
        "run_token_hash CHAR(64)",                 -- sha256 of the oprt_ token minted at claim
    }) do
        db.query("ALTER TABLE ar_runs ADD COLUMN IF NOT EXISTS " .. col)
    end
    db.query([[CREATE UNIQUE INDEX IF NOT EXISTS ar_runs_run_token_hash ON ar_runs (run_token_hash)
        WHERE run_token_hash IS NOT NULL]])

    for _, col in ipairs({
        "request_id VARCHAR(255)",                 -- the agent's control_request id (idempotency)
        "input JSONB",                             -- redacted, at most 8 KB
        "description TEXT",
        "blocked_path TEXT",
        "rule_key VARCHAR(255)",
        "remember BOOLEAN NOT NULL DEFAULT false",
    }) do
        db.query("ALTER TABLE ar_run_requests ADD COLUMN IF NOT EXISTS " .. col)
    end
    db.query([[CREATE UNIQUE INDEX IF NOT EXISTS ar_run_requests_request_id ON ar_run_requests (run_uuid, request_id)]])

    -- User rows are follow-ups and answers (queued until the runner fetches them); assistant rows one per result.
    for _, col in ipairs({
        "status VARCHAR(20) NOT NULL DEFAULT 'delivered' CHECK (status IN ('queued', 'delivered'))",
        "runner_turn INTEGER",
        "cost_estimate NUMERIC(12,4)",
        "num_turns INTEGER",
        "duration_ms BIGINT",
        "needs_input BOOLEAN NOT NULL DEFAULT false",
    }) do
        db.query("ALTER TABLE ar_run_turns ADD COLUMN IF NOT EXISTS " .. col)
    end
    db.query([[CREATE UNIQUE INDEX IF NOT EXISTS ar_run_turns_runner_turn ON ar_run_turns (run_uuid, runner_turn)
        WHERE role = 'assistant']])
    db.query([[CREATE INDEX IF NOT EXISTS idx_ar_run_turns_queued ON ar_run_turns (run_uuid, seq)
        WHERE status = 'queued']])
end
