-- AI Runs: everything configurable (docs/AI_RUNNER.md §27). A connection's kind (a runner, or a source that only
-- reports sessions) and report filter, the workspace's safety additions, routing rules for sessions started by hand,
-- and the one-row platform settings. Idempotent: safe to re-run on a restored database.
return function(schema, db)
    -- §27.1, §27.2: connections registered before this are runners that report everything.
    db.query([[ALTER TABLE ar_runners ADD COLUMN IF NOT EXISTS kind VARCHAR(20) NOT NULL DEFAULT 'runner'
        CHECK (kind IN ('runner', 'source'))]])
    db.query("ALTER TABLE ar_runners ADD COLUMN IF NOT EXISTS report_filter JSONB NOT NULL DEFAULT '{}'")

    -- §27.4: extra_denied_commands, extra_redactions.
    db.query("ALTER TABLE ar_settings ADD COLUMN IF NOT EXISTS safety JSONB NOT NULL DEFAULT '{}'")

    -- §27.3: ordered per workspace, the first enabled match wins. The project and people an action names are
    -- checked against the workspace when it is saved, and again when it is used.
    db.query([[
        CREATE TABLE IF NOT EXISTS ar_track_rules (
            id BIGSERIAL PRIMARY KEY,
            uuid UUID NOT NULL UNIQUE DEFAULT gen_random_uuid(),
            namespace_id INTEGER NOT NULL REFERENCES namespaces(id) ON DELETE CASCADE,
            name VARCHAR(100) NOT NULL DEFAULT '',
            position INTEGER NOT NULL DEFAULT 0,
            enabled BOOLEAN NOT NULL DEFAULT TRUE,
            match JSONB NOT NULL DEFAULT '{}',
            action JSONB NOT NULL DEFAULT '{}',
            created_by VARCHAR(255),
            updated_by VARCHAR(255),
            created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
            updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
        )
    ]])
    db.query("CREATE INDEX IF NOT EXISTS idx_ar_track_rules_ns ON ar_track_rules (namespace_id, position, id)")

    -- §27.5: platform-wide, one row; only the values a platform admin set (the code has the defaults).
    db.query([[
        CREATE TABLE IF NOT EXISTS ar_platform_settings (
            id SMALLINT PRIMARY KEY DEFAULT 1 CHECK (id = 1),
            settings JSONB NOT NULL DEFAULT '{}',
            updated_by VARCHAR(255),
            updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
        )
    ]])
end
