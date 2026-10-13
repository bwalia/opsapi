-- AI Runs schema (docs/AI_RUNNER.md §5, §22): runners, workspace / project settings, versioned prompt templates,
-- runs, folder locks, run events, the machines' session inventory, and (filled in Phase 3) turns and requests.
-- Idempotent: safe to re-run on a restored database.
--
-- References are uuid columns with real foreign keys plus a BEFORE trigger that checks each referenced row is in
-- the row's own workspace, so no write path (API, job, runner) can point one workspace at another's rows.
return function(schema, db)
    db.query([[
        CREATE OR REPLACE FUNCTION ai_runner_same_namespace() RETURNS trigger AS $fn$
        DECLARE
            row_j jsonb := to_jsonb(NEW);
            ns bigint := (row_j ->> 'namespace_id')::bigint;
            col text;
            tbl text;
            ref text;
            ref_ns bigint;
            i int;
        BEGIN
            FOR i IN 0 .. (TG_NARGS / 2) - 1 LOOP
                col := TG_ARGV[i * 2];
                tbl := TG_ARGV[i * 2 + 1];
                ref := row_j ->> col;
                CONTINUE WHEN ref IS NULL;
                IF TG_OP = 'UPDATE' AND ref IS NOT DISTINCT FROM (to_jsonb(OLD) ->> col) THEN
                    CONTINUE;
                END IF;
                ref_ns := NULL;
                IF tbl = 'kanban_tasks' THEN -- no namespace_id: board -> project
                    SELECT p.namespace_id INTO ref_ns
                    FROM kanban_tasks t
                    JOIN kanban_boards b ON b.id = t.board_id
                    JOIN kanban_projects p ON p.id = b.project_id
                    WHERE t.uuid = ref;
                ELSIF tbl LIKE 'ar\_%' THEN       -- our tables: uuid columns (cast the param, keep the index)
                    EXECUTE format('SELECT namespace_id FROM %I WHERE uuid = $1::uuid', tbl) INTO ref_ns USING ref;
                ELSE                              -- core tables: text uuid columns
                    EXECUTE format('SELECT namespace_id FROM %I WHERE uuid = $1', tbl) INTO ref_ns USING ref;
                END IF;
                IF ref_ns IS DISTINCT FROM ns THEN
                    -- Worded so the plugin SDK maps it to 422 "A referenced record does not exist".
                    RAISE EXCEPTION
                        'insert or update on "%" violates foreign key constraint "ai_runner_same_namespace" (%)',
                        TG_TABLE_NAME, col USING ERRCODE = 'foreign_key_violation';
                END IF;
            END LOOP;
            RETURN NEW;
        END
        $fn$ LANGUAGE plpgsql
    ]])

    -- Timestamps a runner reports (any format Postgres reads, else NULL instead of a failed heartbeat).
    db.query([[
        CREATE OR REPLACE FUNCTION ai_runner_ts(t text) RETURNS timestamptz LANGUAGE plpgsql STABLE AS $fn$
        BEGIN
            RETURN t::timestamptz;
        EXCEPTION WHEN OTHERS THEN
            RETURN NULL;
        END
        $fn$
    ]])

    local function same_namespace(tbl, pairs_)
        db.query("DROP TRIGGER IF EXISTS " .. tbl .. "_same_ns ON " .. tbl)
        db.query("CREATE TRIGGER " .. tbl .. "_same_ns BEFORE INSERT OR UPDATE ON " .. tbl
            .. " FOR EACH ROW EXECUTE FUNCTION ai_runner_same_namespace('" .. table.concat(pairs_, "', '") .. "')")
    end

    -- A machine registration. status is what a manager set; online/offline comes from last_heartbeat_at.
    db.query([[
        CREATE TABLE IF NOT EXISTS ar_runners (
            id BIGSERIAL PRIMARY KEY,
            uuid UUID NOT NULL UNIQUE DEFAULT gen_random_uuid(),
            namespace_id INTEGER NOT NULL REFERENCES namespaces(id) ON DELETE CASCADE,
            name VARCHAR(100) NOT NULL,
            status VARCHAR(20) NOT NULL DEFAULT 'active' CHECK (status IN ('active', 'paused', 'revoked')),
            labels JSONB NOT NULL DEFAULT '[]',
            capabilities JSONB NOT NULL DEFAULT '{}',
            repos JSONB NOT NULL DEFAULT '[]',
            host VARCHAR(255),
            os VARCHAR(100),
            version VARCHAR(100),
            token_hash CHAR(64) NOT NULL UNIQUE,
            token_hint VARCHAR(20) NOT NULL,
            last_heartbeat_at TIMESTAMPTZ,
            created_by VARCHAR(255),
            revoked_at TIMESTAMPTZ,
            created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
            updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
        )
    ]])
    db.query([[CREATE UNIQUE INDEX IF NOT EXISTS ar_runners_name ON ar_runners (namespace_id, lower(name))
        WHERE status <> 'revoked']])
    db.query("CREATE INDEX IF NOT EXISTS idx_ar_runners_ns ON ar_runners (namespace_id, status)")

    db.query([[
        CREATE TABLE IF NOT EXISTS ar_settings (
            namespace_id INTEGER PRIMARY KEY REFERENCES namespaces(id) ON DELETE CASCADE,
            output_mode VARCHAR(20) NOT NULL DEFAULT 'pull_request'
                CHECK (output_mode IN ('pull_request', 'branch', 'local')),
            pr_draft BOOLEAN NOT NULL DEFAULT TRUE,
            pr_base VARCHAR(255) NOT NULL DEFAULT 'main',
            max_run_minutes INTEGER NOT NULL DEFAULT 60 CHECK (max_run_minutes BETWEEN 1 AND 1440),
            task_automation JSONB NOT NULL DEFAULT '{}',
            approval_policy JSONB NOT NULL DEFAULT '{}',
            updated_by VARCHAR(255),
            created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
            updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
        )
    ]])

    db.query([[
        CREATE TABLE IF NOT EXISTS ar_project_settings (
            id BIGSERIAL PRIMARY KEY,
            uuid UUID NOT NULL UNIQUE DEFAULT gen_random_uuid(),
            namespace_id INTEGER NOT NULL REFERENCES namespaces(id) ON DELETE CASCADE,
            project_uuid VARCHAR(255) NOT NULL REFERENCES kanban_projects(uuid) ON DELETE CASCADE,
            default_repo_paths JSONB NOT NULL DEFAULT '{}',
            output_mode VARCHAR(20) CHECK (output_mode IN ('pull_request', 'branch', 'local')),
            base_branch VARCHAR(255),
            updated_by VARCHAR(255),
            created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
            updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
            UNIQUE (namespace_id, project_uuid)
        )
    ]])
    same_namespace("ar_project_settings", { "project_uuid", "kanban_projects" })

    -- Versioned: every save is a new row. project_uuid NULL = the workspace template.
    db.query([[
        CREATE TABLE IF NOT EXISTS ar_prompt_templates (
            id BIGSERIAL PRIMARY KEY,
            uuid UUID NOT NULL UNIQUE DEFAULT gen_random_uuid(),
            namespace_id INTEGER NOT NULL REFERENCES namespaces(id) ON DELETE CASCADE,
            project_uuid VARCHAR(255) REFERENCES kanban_projects(uuid) ON DELETE CASCADE,
            name VARCHAR(100) NOT NULL DEFAULT 'default',
            version INTEGER NOT NULL CHECK (version >= 1),
            body TEXT NOT NULL,
            variables JSONB NOT NULL DEFAULT '[]',
            is_default BOOLEAN NOT NULL DEFAULT FALSE,
            created_by VARCHAR(255),
            created_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
        )
    ]])
    db.query([[CREATE UNIQUE INDEX IF NOT EXISTS ar_prompt_templates_version
        ON ar_prompt_templates (namespace_id, COALESCE(project_uuid, ''), name, version)]])
    same_namespace("ar_prompt_templates", { "project_uuid", "kanban_projects" })

    -- One AI run of one task. Open: queued .. cancelling; terminal: succeeded, failed, cancelled, lost.
    -- status_seq is the last runner sequence number applied (a status with a lower or equal seq is stale).
    db.query([[
        CREATE TABLE IF NOT EXISTS ar_runs (
            id BIGSERIAL PRIMARY KEY,
            uuid UUID NOT NULL UNIQUE DEFAULT gen_random_uuid(),
            namespace_id INTEGER NOT NULL REFERENCES namespaces(id) ON DELETE CASCADE,
            task_uuid VARCHAR(255) NOT NULL REFERENCES kanban_tasks(uuid) ON DELETE CASCADE,
            project_uuid VARCHAR(255) REFERENCES kanban_projects(uuid) ON DELETE CASCADE,
            task_snapshot JSONB NOT NULL DEFAULT '{}',
            requested_by VARCHAR(255) NOT NULL,
            assignee_uuid VARCHAR(255),
            runner_uuid UUID NOT NULL REFERENCES ar_runners(uuid) ON DELETE CASCADE,
            profile VARCHAR(80) NOT NULL,
            model VARCHAR(120),
            repo_path TEXT NOT NULL,
            repo_remote TEXT,
            base_branch VARCHAR(255),
            work_branch VARCHAR(255) NOT NULL,
            previous_branch VARCHAR(255),
            output_mode VARCHAR(20) NOT NULL CHECK (output_mode IN ('pull_request', 'branch', 'local')),
            pr_draft BOOLEAN NOT NULL DEFAULT TRUE,
            pr_base VARCHAR(255),
            prompt TEXT NOT NULL,
            template_uuid UUID,
            template_version INTEGER NOT NULL DEFAULT 0,
            prompt_sha256 CHAR(64) NOT NULL,
            status VARCHAR(30) NOT NULL DEFAULT 'queued' CHECK (status IN ('queued', 'claimed', 'starting',
                'running', 'waiting_permission', 'needs_input', 'cancelling', 'succeeded', 'failed', 'cancelled',
                'lost')),
            status_seq INTEGER NOT NULL DEFAULT 0,
            attempt INTEGER NOT NULL DEFAULT 1,
            retry_of UUID REFERENCES ar_runs(uuid) ON DELETE SET NULL,
            idempotency_key VARCHAR(255),
            timeout_s INTEGER,
            lease_until TIMESTAMPTZ,
            heartbeat_at TIMESTAMPTZ,
            claimed_at TIMESTAMPTZ,
            started_at TIMESTAMPTZ,
            finished_at TIMESTAMPTZ,
            cancel_requested_at TIMESTAMPTZ,
            cancel_requested_by VARCHAR(255),
            pid INTEGER,
            agent_session_id VARCHAR(255),
            exit_code INTEGER,
            error_category VARCHAR(40),
            error TEXT,
            summary TEXT,
            commit_sha VARCHAR(64),
            pr_url TEXT,
            created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
            updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
        )
    ]])
    -- Layer 1 of conflict prevention (§9): one open run per task, whoever and wherever started it.
    db.query([[CREATE UNIQUE INDEX IF NOT EXISTS ar_runs_one_open_per_task ON ar_runs (task_uuid)
        WHERE status IN ('queued', 'claimed', 'starting', 'running', 'waiting_permission', 'needs_input',
                         'cancelling')]])
    -- Lists (newest first, by status, mine), task history, claim / heartbeat / cancel list, sweeps.
    db.query("CREATE INDEX IF NOT EXISTS idx_ar_runs_ns_created ON ar_runs (namespace_id, created_at DESC)")
    db.query("CREATE INDEX IF NOT EXISTS idx_ar_runs_ns_status ON ar_runs (namespace_id, status, created_at DESC)")
    db.query([[CREATE INDEX IF NOT EXISTS idx_ar_runs_requester ON ar_runs (namespace_id, requested_by,
        created_at DESC)]])
    db.query("CREATE INDEX IF NOT EXISTS idx_ar_runs_task ON ar_runs (task_uuid, created_at DESC)")
    db.query("CREATE INDEX IF NOT EXISTS idx_ar_runs_project ON ar_runs (namespace_id, project_uuid)")
    db.query("CREATE INDEX IF NOT EXISTS idx_ar_runs_runner ON ar_runs (runner_uuid, status)")
    db.query([[CREATE INDEX IF NOT EXISTS idx_ar_runs_lease ON ar_runs (lease_until)
        WHERE status IN ('claimed', 'starting', 'running', 'waiting_permission', 'needs_input', 'cancelling')]])
    db.query("CREATE INDEX IF NOT EXISTS idx_ar_runs_queued ON ar_runs (created_at) WHERE status = 'queued'")
    same_namespace("ar_runs", { "task_uuid", "kanban_tasks", "project_uuid", "kanban_projects",
        "runner_uuid", "ar_runners", "retry_of", "ar_runs" })

    -- Layer 2 (§9): a folder lock, held while its run is open (the row is deleted on release).
    db.query([[
        CREATE TABLE IF NOT EXISTS ar_locks (
            id BIGSERIAL PRIMARY KEY,
            lock_key TEXT NOT NULL,
            namespace_id INTEGER NOT NULL REFERENCES namespaces(id) ON DELETE CASCADE,
            run_uuid UUID NOT NULL REFERENCES ar_runs(uuid) ON DELETE CASCADE,
            runner_uuid UUID REFERENCES ar_runners(uuid) ON DELETE CASCADE,
            scope VARCHAR(20) NOT NULL DEFAULT 'repo',
            repo_path TEXT,
            expires_at TIMESTAMPTZ,
            created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
            CONSTRAINT ar_locks_lock_key_unique UNIQUE (lock_key)
        )
    ]])
    db.query("CREATE INDEX IF NOT EXISTS idx_ar_locks_run ON ar_locks (run_uuid)")
    db.query("CREATE INDEX IF NOT EXISTS idx_ar_locks_expires ON ar_locks (expires_at) WHERE expires_at IS NOT NULL")
    same_namespace("ar_locks", { "run_uuid", "ar_runs", "runner_uuid", "ar_runners" })

    db.query([[
        CREATE TABLE IF NOT EXISTS ar_run_events (
            id BIGSERIAL PRIMARY KEY,
            run_uuid UUID NOT NULL REFERENCES ar_runs(uuid) ON DELETE CASCADE,
            namespace_id INTEGER NOT NULL REFERENCES namespaces(id) ON DELETE CASCADE,
            seq INTEGER NOT NULL CHECK (seq >= 0),
            type VARCHAR(20) NOT NULL CHECK (type IN ('log', 'progress', 'tool', 'usage')),
            text TEXT,
            data JSONB,
            at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
            UNIQUE (run_uuid, seq)
        )
    ]])
    same_namespace("ar_run_events", { "run_uuid", "ar_runs" })

    -- Layer 3 (§9): each runner's latest session inventory, replaced on every heartbeat.
    db.query([[
        CREATE TABLE IF NOT EXISTS ar_sessions (
            runner_uuid UUID NOT NULL REFERENCES ar_runners(uuid) ON DELETE CASCADE,
            namespace_id INTEGER NOT NULL REFERENCES namespaces(id) ON DELETE CASCADE,
            session_key VARCHAR(255) NOT NULL,
            tool VARCHAR(40),
            status VARCHAR(40),
            cwd TEXT,
            branch VARCHAR(255),
            session_id VARCHAR(255),
            started_at TIMESTAMPTZ,
            updated_at TIMESTAMPTZ,
            prompt_preview TEXT,
            labels JSONB NOT NULL DEFAULT '{}',
            run_uuid UUID REFERENCES ar_runs(uuid) ON DELETE SET NULL,
            managed BOOLEAN NOT NULL DEFAULT FALSE,
            seen_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
            PRIMARY KEY (runner_uuid, session_key)
        )
    ]])
    same_namespace("ar_sessions", { "runner_uuid", "ar_runners", "run_uuid", "ar_runs" })

    -- Phase 3 (session tracking, permission bridge): created now so the schema is complete.
    db.query([[
        CREATE TABLE IF NOT EXISTS ar_run_turns (
            id BIGSERIAL PRIMARY KEY,
            uuid UUID NOT NULL UNIQUE DEFAULT gen_random_uuid(),
            run_uuid UUID NOT NULL REFERENCES ar_runs(uuid) ON DELETE CASCADE,
            namespace_id INTEGER NOT NULL REFERENCES namespaces(id) ON DELETE CASCADE,
            seq INTEGER NOT NULL,
            role VARCHAR(20) NOT NULL CHECK (role IN ('user', 'assistant')),
            author_user_uuid VARCHAR(255),
            text TEXT,
            model VARCHAR(120),
            tokens_in BIGINT NOT NULL DEFAULT 0,
            tokens_out BIGINT NOT NULL DEFAULT 0,
            cache_read BIGINT NOT NULL DEFAULT 0,
            cache_write BIGINT NOT NULL DEFAULT 0,
            at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
            UNIQUE (run_uuid, seq)
        )
    ]])
    same_namespace("ar_run_turns", { "run_uuid", "ar_runs" })

    db.query([[
        CREATE TABLE IF NOT EXISTS ar_run_requests (
            id BIGSERIAL PRIMARY KEY,
            uuid UUID NOT NULL UNIQUE DEFAULT gen_random_uuid(),
            run_uuid UUID NOT NULL REFERENCES ar_runs(uuid) ON DELETE CASCADE,
            namespace_id INTEGER NOT NULL REFERENCES namespaces(id) ON DELETE CASCADE,
            kind VARCHAR(20) NOT NULL CHECK (kind IN ('permission', 'tool_call')),
            tool VARCHAR(120),
            input_summary TEXT,
            tool_use_id VARCHAR(255),
            status VARCHAR(20) NOT NULL DEFAULT 'pending' CHECK (status IN ('pending', 'allowed', 'denied', 'expired')),
            decided_by VARCHAR(255),
            decided_at TIMESTAMPTZ,
            reason TEXT,
            expires_at TIMESTAMPTZ,
            created_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
        )
    ]])
    db.query("CREATE INDEX IF NOT EXISTS idx_ar_run_requests_run ON ar_run_requests (run_uuid)")
    db.query([[CREATE INDEX IF NOT EXISTS idx_ar_run_requests_pending ON ar_run_requests (namespace_id)
        WHERE status = 'pending']])
    same_namespace("ar_run_requests", { "run_uuid", "ar_runs" })
end
