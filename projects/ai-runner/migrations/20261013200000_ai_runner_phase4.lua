-- AI Runs Phase 4 (docs/AI_RUNNER.md §24): workspace guards (similar work, caps, daily tokens, retention), the
-- indexes the sessions list, overview and retention read, pg_trgm for similar work, and the notification types.
-- Idempotent: safe to re-run on a restored database.
return function(schema, db)
    db.query("ALTER TABLE ar_settings ADD COLUMN IF NOT EXISTS guards JSONB NOT NULL DEFAULT '{}'")

    -- Similar work compares task titles with pg_trgm. A hosted Postgres may refuse CREATE EXTENSION to the app role
    -- (an admin installs it instead): that must not fail the migration, the check is skipped while it's missing.
    db.query([[
        DO $fn$ BEGIN
            CREATE EXTENSION IF NOT EXISTS pg_trgm;
        EXCEPTION WHEN OTHERS THEN
            RAISE NOTICE 'ai_runner: pg_trgm not installed (%), similar-work checks are skipped', SQLERRM;
        END $fn$
    ]])

    -- GET /sessions (the workspace's machines), the overview (decided requests, finished runs, today's cost) and
    -- the retention job (finished runs).
    db.query("CREATE INDEX IF NOT EXISTS idx_ar_sessions_ns ON ar_sessions (namespace_id, runner_uuid)")
    db.query([[CREATE INDEX IF NOT EXISTS idx_ar_run_requests_decided ON ar_run_requests (namespace_id, decided_at)
        WHERE status IN ('allowed', 'denied')]])
    db.query([[CREATE INDEX IF NOT EXISTS idx_ar_runs_finished ON ar_runs (namespace_id, finished_at)
        WHERE finished_at IS NOT NULL]])
    db.query([[CREATE INDEX IF NOT EXISTS idx_ar_run_turns_ns_at ON ar_run_turns (namespace_id, at)
        WHERE role = 'assistant']])

    -- Notifications to deciders (§24.6) go through the kanban notification center, whose CHECK only knows the
    -- kanban types. Widen whatever the check currently is (not a copy of today's list), so a type core adds later
    -- is kept even when this migration re-runs.
    db.query([[
        DO $fn$
        DECLARE def text;
        BEGIN
            SELECT pg_get_constraintdef(c.oid) INTO def FROM pg_constraint c
            WHERE c.conname = 'kanban_notifications_type_check'
              AND c.conrelid = to_regclass('kanban_notifications');
            IF def IS NOT NULL AND position('ai_run_permission' IN def) = 0 THEN
                ALTER TABLE kanban_notifications DROP CONSTRAINT kanban_notifications_type_check;
                EXECUTE 'ALTER TABLE kanban_notifications ADD CONSTRAINT kanban_notifications_type_check CHECK ('
                    || substr(def, 7) -- "CHECK (...)" -> "(...)"
                    || ' OR type IN (''ai_run_permission'', ''ai_run_approval'', ''ai_run_input''))';
            END IF;
        END $fn$
    ]])
end
