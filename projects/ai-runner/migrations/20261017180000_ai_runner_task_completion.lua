-- AI task completion: per-project context (skills/MD/target repo/vault), task work records,
-- multi-PR attach + manager sign-off, executor kind on runs (docs plan: AI task completion).
return function(schema, db)
    db.query([[
        ALTER TABLE ar_project_settings
            ADD COLUMN IF NOT EXISTS target_repo_url TEXT,
            ADD COLUMN IF NOT EXISTS skills_git_urls JSONB NOT NULL DEFAULT '[]',
            ADD COLUMN IF NOT EXISTS md_refs JSONB NOT NULL DEFAULT '[]',
            ADD COLUMN IF NOT EXISTS vault_url TEXT,
            ADD COLUMN IF NOT EXISTS vault_secret_path TEXT,
            ADD COLUMN IF NOT EXISTS vault_mount_path TEXT DEFAULT 'secret',
            ADD COLUMN IF NOT EXISTS vault_token_sealed TEXT,
            ADD COLUMN IF NOT EXISTS allowed_executors JSONB NOT NULL DEFAULT '[]',
            ADD COLUMN IF NOT EXISTS executor_locked BOOLEAN NOT NULL DEFAULT FALSE,
            ADD COLUMN IF NOT EXISTS default_executor TEXT
    ]])

    db.query([[
        ALTER TABLE ar_runs
            ADD COLUMN IF NOT EXISTS executor_kind VARCHAR(40) NOT NULL DEFAULT 'machine',
            ADD COLUMN IF NOT EXISTS provider_uuid VARCHAR(255),
            ADD COLUMN IF NOT EXISTS context_snapshot JSONB NOT NULL DEFAULT '{}',
            ADD COLUMN IF NOT EXISTS jobshout_run_id TEXT,
            ADD COLUMN IF NOT EXISTS conversation_summary TEXT
    ]])

    db.query([[
        CREATE TABLE IF NOT EXISTS ar_task_work (
            id BIGSERIAL PRIMARY KEY,
            uuid UUID NOT NULL UNIQUE DEFAULT gen_random_uuid(),
            namespace_id INTEGER NOT NULL REFERENCES namespaces(id) ON DELETE CASCADE,
            task_uuid VARCHAR(255) NOT NULL,
            project_uuid VARCHAR(255) NOT NULL,
            run_uuid UUID REFERENCES ar_runs(uuid) ON DELETE SET NULL,
            status VARCHAR(40) NOT NULL DEFAULT 'started',
            executor_kind VARCHAR(40) NOT NULL DEFAULT 'machine',
            provider_uuid VARCHAR(255),
            prompt TEXT NOT NULL DEFAULT '',
            prompt_sha256 VARCHAR(64),
            context_snapshot JSONB NOT NULL DEFAULT '{}',
            conversation_summary TEXT,
            summary TEXT,
            requested_by VARCHAR(255),
            created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
            updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
        )
    ]])
    db.query([[CREATE INDEX IF NOT EXISTS ar_task_work_task_idx
        ON ar_task_work (namespace_id, task_uuid, created_at DESC)]])
    db.query([[CREATE INDEX IF NOT EXISTS ar_task_work_run_idx ON ar_task_work (run_uuid)]])

    db.query([[
        CREATE TABLE IF NOT EXISTS ar_task_prs (
            id BIGSERIAL PRIMARY KEY,
            uuid UUID NOT NULL UNIQUE DEFAULT gen_random_uuid(),
            namespace_id INTEGER NOT NULL REFERENCES namespaces(id) ON DELETE CASCADE,
            task_uuid VARCHAR(255) NOT NULL,
            project_uuid VARCHAR(255) NOT NULL,
            run_uuid UUID REFERENCES ar_runs(uuid) ON DELETE SET NULL,
            repo TEXT NOT NULL,
            pr_url TEXT NOT NULL,
            pr_number INTEGER,
            state VARCHAR(40) NOT NULL DEFAULT 'open',
            review_status VARCHAR(40) NOT NULL DEFAULT 'pending',
            reviewed_by VARCHAR(255),
            reviewed_at TIMESTAMPTZ,
            review_note TEXT,
            created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
            updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
            UNIQUE (namespace_id, run_uuid)
        )
    ]])
    db.query([[CREATE INDEX IF NOT EXISTS ar_task_prs_task_idx
        ON ar_task_prs (namespace_id, task_uuid, created_at DESC)]])
end
