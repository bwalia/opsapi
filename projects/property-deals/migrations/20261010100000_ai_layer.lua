-- Phase 5: the AI layer (SPEC §3.5) and the iOS requests answered at its start.
--   * chases may hang off a lead before there is a deal (ios-contact-log-without-deal)
--   * per-user notification preferences (ios-notification-preferences)
--   * model routing per job type, per-agent config, the JobShout mapping
--   * email connectors (IMAP / Gmail / Microsoft 365) and the inbound messages they fetch
-- Provider keys live in core namespace_ai_providers (gap map D10/D11).
return function(schema, db)
    local function same_namespace(tbl, pairs_)
        db.query("DROP TRIGGER IF EXISTS " .. tbl .. "_same_ns ON " .. tbl)
        db.query("CREATE TRIGGER " .. tbl .. "_same_ns BEFORE INSERT OR UPDATE ON " .. tbl
            .. " FOR EACH ROW EXECUTE FUNCTION property_deals_same_namespace('" .. table.concat(pairs_, "', '") .. "')")
    end

    -- The same-workspace guard learns one more uuid-typed table (core namespace_ai_providers).
    db.query([[
        CREATE OR REPLACE FUNCTION property_deals_same_namespace() RETURNS trigger AS $fn$
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
                IF tbl = 'kanban_tasks' THEN
                    SELECT p.namespace_id INTO ref_ns
                    FROM kanban_tasks t
                    JOIN kanban_boards b ON b.id = t.board_id
                    JOIN kanban_projects p ON p.id = b.project_id
                    WHERE t.uuid = ref;
                ELSIF tbl = 'users' THEN
                    SELECT m.namespace_id INTO ref_ns
                    FROM users u
                    JOIN namespace_members m ON m.user_id = u.id AND m.namespace_id = ns
                    WHERE u.uuid = ref;
                ELSIF tbl LIKE 'property\_deals\_%' OR tbl = 'namespace_ai_providers' THEN -- uuid columns (cast the param, keep the index)
                    EXECUTE format('SELECT namespace_id FROM %I WHERE uuid = $1::uuid', tbl) INTO ref_ns USING ref;
                ELSE                                     -- core tables: text/varchar uuid columns
                    EXECUTE format('SELECT namespace_id FROM %I WHERE uuid = $1', tbl) INTO ref_ns USING ref;
                END IF;
                IF ref_ns IS DISTINCT FROM ns THEN
                    -- Worded so helper.plugin-sdk maps it to 422 "A referenced record does not exist".
                    RAISE EXCEPTION 'insert or update on "%" violates foreign key constraint "property_deals_same_namespace" (%)',
                        TG_TABLE_NAME, col USING ERRCODE = 'foreign_key_violation';
                END IF;
            END LOOP;
            RETURN NEW;
        END
        $fn$ LANGUAGE plpgsql
    ]])

    -- Contact log without a deal: a lead-stage call or WhatsApp is logged on the
    -- lead; when the lead becomes a deal its chases move onto the deal.
    db.query("ALTER TABLE property_deals_chases ADD COLUMN IF NOT EXISTS lead_uuid TEXT REFERENCES crm_leads(uuid) ON DELETE SET NULL")
    db.query("ALTER TABLE property_deals_chases ADD COLUMN IF NOT EXISTS outcome VARCHAR(40)")
    db.query("ALTER TABLE property_deals_chases ALTER COLUMN deal_uuid DROP NOT NULL")
    db.query([[
        DO $$ BEGIN
            ALTER TABLE property_deals_chases ADD CONSTRAINT property_deals_chases_subject
                CHECK (num_nonnulls(deal_uuid, lead_uuid) >= 1);
        EXCEPTION WHEN duplicate_object THEN NULL;
        END $$
    ]])
    db.query("CREATE INDEX IF NOT EXISTS idx_pd_chases_lead ON property_deals_chases (namespace_id, lead_uuid, sent_at DESC) WHERE lead_uuid IS NOT NULL")
    same_namespace("property_deals_chases", {
        "deal_uuid", "property_deals_deals", "enquiry_uuid", "property_deals_enquiries", "task_uuid", "kanban_tasks",
        "lead_uuid", "crm_leads",
    })

    -- Agent runs: why it ran, which attempt, the reviewer's note it retried with.
    db.query("ALTER TABLE property_deals_agent_runs ADD COLUMN IF NOT EXISTS trigger VARCHAR(20) NOT NULL DEFAULT 'manual'")
    db.query("ALTER TABLE property_deals_agent_runs ADD COLUMN IF NOT EXISTS attempt INTEGER NOT NULL DEFAULT 1")
    db.query("ALTER TABLE property_deals_agent_runs ADD COLUMN IF NOT EXISTS retry_note TEXT")
    db.query("ALTER TABLE property_deals_agent_runs ADD COLUMN IF NOT EXISTS provider_uuid UUID")
    db.query("ALTER TABLE property_deals_agent_runs ADD COLUMN IF NOT EXISTS fallback_used BOOLEAN NOT NULL DEFAULT FALSE")
    db.query([[
        CREATE INDEX IF NOT EXISTS idx_pd_agent_runs_open ON property_deals_agent_runs (status)
        WHERE status IN ('queued', 'running')
    ]])

    -- Approvals: how many times the executor tried, and JobShout's own status.
    db.query("ALTER TABLE property_deals_approvals ADD COLUMN IF NOT EXISTS execution_attempts INTEGER NOT NULL DEFAULT 0")
    db.query("ALTER TABLE property_deals_approvals ADD COLUMN IF NOT EXISTS jobshout_provider_uuid UUID")
    db.query([[
        CREATE UNIQUE INDEX IF NOT EXISTS idx_pd_approvals_jobshout ON property_deals_approvals (namespace_id, jobshout_approval_id)
        WHERE jobshout_approval_id IS NOT NULL
    ]])

    -- Per-user notification preferences. A missing row = everything on.
    db.query([[
        CREATE TABLE IF NOT EXISTS property_deals_notification_prefs (
            id BIGSERIAL PRIMARY KEY,
            namespace_id INTEGER NOT NULL REFERENCES namespaces(id) ON DELETE CASCADE,
            user_uuid VARCHAR(255) NOT NULL REFERENCES users(uuid) ON DELETE CASCADE,
            prefs JSONB NOT NULL DEFAULT '{}',
            created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
            updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
            UNIQUE (namespace_id, user_uuid)
        )
    ]])
    same_namespace("property_deals_notification_prefs", { "user_uuid", "users" })

    -- Model per job type: an ordered chain of { provider_uuid, model } (the
    -- fallback order). local_only keeps the job on is_local providers.
    db.query([[
        CREATE TABLE IF NOT EXISTS property_deals_ai_routes (
            id BIGSERIAL PRIMARY KEY,
            uuid UUID NOT NULL UNIQUE DEFAULT gen_random_uuid(),
            namespace_id INTEGER NOT NULL REFERENCES namespaces(id) ON DELETE CASCADE,
            job_type VARCHAR(20) NOT NULL CHECK (job_type IN ('classify', 'extract', 'draft', 'plan', 'chat', 'summarise')),
            chain JSONB NOT NULL DEFAULT '[]',
            local_only BOOLEAN NOT NULL DEFAULT FALSE,
            max_tokens INTEGER CHECK (max_tokens BETWEEN 64 AND 200000),
            created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
            updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
            UNIQUE (namespace_id, job_type)
        )
    ]])

    -- Per-agent settings: on/off, built-in or JobShout, local only, auto pickup.
    db.query([[
        CREATE TABLE IF NOT EXISTS property_deals_agent_configs (
            id BIGSERIAL PRIMARY KEY,
            uuid UUID NOT NULL UNIQUE DEFAULT gen_random_uuid(),
            namespace_id INTEGER NOT NULL REFERENCES namespaces(id) ON DELETE CASCADE,
            agent_key VARCHAR(80) NOT NULL,
            enabled BOOLEAN NOT NULL DEFAULT TRUE,
            route VARCHAR(20) NOT NULL DEFAULT 'builtin' CHECK (route IN ('builtin', 'jobshout')),
            jobshout_provider_uuid UUID REFERENCES namespace_ai_providers(uuid) ON DELETE SET NULL,
            jobshout_agent_id VARCHAR(64),
            jobshout_project_id VARCHAR(64),
            fallback_to_builtin BOOLEAN NOT NULL DEFAULT TRUE,
            local_only BOOLEAN NOT NULL DEFAULT FALSE,
            approval_rule VARCHAR(20) CHECK (approval_rule IN ('any_operator', 'manager', 'two_person')),
            auto_pickup BOOLEAN NOT NULL DEFAULT FALSE,
            auto_pickup_at VARCHAR(5) CHECK (auto_pickup_at ~ '^([01][0-9]|2[0-3]):[0-5][0-9]$'),
            last_auto_run_on DATE,
            created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
            updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
            UNIQUE (namespace_id, agent_key)
        )
    ]])
    same_namespace("property_deals_agent_configs", { "jobshout_provider_uuid", "namespace_ai_providers" })

    -- Mailboxes the legal chaser reads. The secret (IMAP password, OAuth refresh
    -- token) is sealed with AES-256-GCM; `cursor` remembers where sync stopped.
    db.query([[
        CREATE TABLE IF NOT EXISTS property_deals_mail_connectors (
            id BIGSERIAL PRIMARY KEY,
            uuid UUID NOT NULL UNIQUE DEFAULT gen_random_uuid(),
            namespace_id INTEGER NOT NULL REFERENCES namespaces(id) ON DELETE CASCADE,
            name VARCHAR(120) NOT NULL,
            kind VARCHAR(10) NOT NULL CHECK (kind IN ('imap', 'gmail', 'm365')),
            config JSONB NOT NULL DEFAULT '{}',
            secret_sealed TEXT,
            secret_hint VARCHAR(12),
            enabled BOOLEAN NOT NULL DEFAULT TRUE,
            cursor JSONB NOT NULL DEFAULT '{}',
            last_synced_at TIMESTAMPTZ,
            last_error TEXT,
            created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
            updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
            UNIQUE (namespace_id, name)
        )
    ]])

    -- What the connectors fetched. Stored as data: agents read it inside a
    -- fenced <untrusted_email> block and can never act on its instructions.
    db.query([[
        CREATE TABLE IF NOT EXISTS property_deals_inbound_messages (
            id BIGSERIAL PRIMARY KEY,
            uuid UUID NOT NULL UNIQUE DEFAULT gen_random_uuid(),
            namespace_id INTEGER NOT NULL REFERENCES namespaces(id) ON DELETE CASCADE,
            connector_uuid UUID REFERENCES property_deals_mail_connectors(uuid) ON DELETE SET NULL,
            external_id VARCHAR(255) NOT NULL,
            from_address VARCHAR(255),
            from_name VARCHAR(255),
            to_address TEXT,
            subject TEXT,
            received_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
            body_text TEXT,
            deal_uuid UUID REFERENCES property_deals_deals(uuid) ON DELETE SET NULL,
            matched_by VARCHAR(30),
            chase_uuid UUID REFERENCES property_deals_chases(uuid) ON DELETE SET NULL,
            agent_run_uuid UUID REFERENCES property_deals_agent_runs(uuid) ON DELETE SET NULL,
            processed_at TIMESTAMPTZ,
            created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
            UNIQUE (namespace_id, external_id)
        )
    ]])
    db.query("CREATE INDEX IF NOT EXISTS idx_pd_inbound_deal ON property_deals_inbound_messages (namespace_id, deal_uuid, received_at DESC)")
    db.query([[
        CREATE INDEX IF NOT EXISTS idx_pd_inbound_unprocessed ON property_deals_inbound_messages (namespace_id, received_at)
        WHERE processed_at IS NULL
    ]])
    same_namespace("property_deals_inbound_messages", {
        "connector_uuid", "property_deals_mail_connectors", "deal_uuid", "property_deals_deals",
        "chase_uuid", "property_deals_chases", "agent_run_uuid", "property_deals_agent_runs",
    })
end
