-- AI Runs: sessions started by hand become tasks (docs/AI_RUNNER.md §26). The workspace setting, the sessions' first
-- prompt (the task title), one row per tracked session (its task, when it was last seen, when it ended) and the
-- notification type. Idempotent: safe to re-run on a restored database.
return function(schema, db)
    db.query("ALTER TABLE ar_settings ADD COLUMN IF NOT EXISTS session_tracking JSONB NOT NULL DEFAULT '{}'")
    db.query("ALTER TABLE ar_sessions ADD COLUMN IF NOT EXISTS first_prompt TEXT")

    -- session_ref: Claude's session id, else the inventory key. The unique key is what makes one task per session,
    -- whichever pod or heartbeat sees it first.
    db.query([[
        CREATE TABLE IF NOT EXISTS ar_tracked_sessions (
            id BIGSERIAL PRIMARY KEY,
            namespace_id INTEGER NOT NULL REFERENCES namespaces(id) ON DELETE CASCADE,
            runner_uuid UUID NOT NULL REFERENCES ar_runners(uuid) ON DELETE CASCADE,
            session_ref VARCHAR(255) NOT NULL,
            task_uuid VARCHAR(255) REFERENCES kanban_tasks(uuid) ON DELETE SET NULL,
            tool VARCHAR(40),
            cwd TEXT,
            branch VARCHAR(255),
            first_seen_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
            last_seen_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
            ended_at TIMESTAMPTZ,
            UNIQUE (runner_uuid, session_ref)
        )
    ]])
    -- The lease sweep looks for open ones nobody reported for a while.
    db.query([[CREATE INDEX IF NOT EXISTS idx_ar_tracked_sessions_open ON ar_tracked_sessions (last_seen_at)
        WHERE ended_at IS NULL]])
    db.query("DROP TRIGGER IF EXISTS ar_tracked_sessions_same_ns ON ar_tracked_sessions")
    db.query([[CREATE TRIGGER ar_tracked_sessions_same_ns BEFORE INSERT OR UPDATE ON ar_tracked_sessions FOR EACH ROW
        EXECUTE FUNCTION ai_runner_same_namespace('runner_uuid', 'ar_runners', 'task_uuid', 'kanban_tasks')]])

    -- Widen whatever the notification type check is now (as migration 3 did), once.
    db.query([[
        DO $fn$
        DECLARE def text;
        BEGIN
            SELECT pg_get_constraintdef(c.oid) INTO def FROM pg_constraint c
            WHERE c.conname = 'kanban_notifications_type_check'
              AND c.conrelid = to_regclass('kanban_notifications');
            IF def IS NOT NULL AND position('ai_session_task' IN def) = 0 THEN
                ALTER TABLE kanban_notifications DROP CONSTRAINT kanban_notifications_type_check;
                EXECUTE 'ALTER TABLE kanban_notifications ADD CONSTRAINT kanban_notifications_type_check CHECK ('
                    || substr(def, 7) -- "CHECK (...)" -> "(...)"
                    || ' OR type = ''ai_session_task'')';
            END IF;
        END $fn$
    ]])
end
