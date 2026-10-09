-- Agent runs, approvals, buyer matches, the working-day calendar and the
-- per-workspace plugin state (gap map §2.13–2.16).
return function(schema, db)
    local function same_namespace(tbl, pairs_)
        db.query("DROP TRIGGER IF EXISTS " .. tbl .. "_same_ns ON " .. tbl)
        db.query("CREATE TRIGGER " .. tbl .. "_same_ns BEFORE INSERT OR UPDATE ON " .. tbl
            .. " FOR EACH ROW EXECUTE FUNCTION property_deals_same_namespace('" .. table.concat(pairs_, "', '") .. "')")
    end

    -- One row per agent attempt at a task: built-in provider or JobShout.
    db.query([[
        CREATE TABLE IF NOT EXISTS property_deals_agent_runs (
            id BIGSERIAL PRIMARY KEY,
            uuid UUID NOT NULL UNIQUE DEFAULT gen_random_uuid(),
            namespace_id INTEGER NOT NULL REFERENCES namespaces(id) ON DELETE CASCADE,
            task_uuid VARCHAR(255) REFERENCES kanban_tasks(uuid) ON DELETE SET NULL,
            deal_uuid UUID REFERENCES property_deals_deals(uuid) ON DELETE CASCADE,
            agent_key VARCHAR(80) NOT NULL,
            provider VARCHAR(40) NOT NULL,
            model VARCHAR(120),
            prompt_version VARCHAR(40),
            status VARCHAR(20) NOT NULL DEFAULT 'queued'
                CHECK (status IN ('queued', 'running', 'succeeded', 'failed', 'cancelled')),
            input_snapshot JSONB NOT NULL DEFAULT '{}',
            steps JSONB NOT NULL DEFAULT '[]',
            output_draft TEXT,
            output JSONB,
            sources JSONB NOT NULL DEFAULT '[]',
            error TEXT,
            tokens_in INTEGER NOT NULL DEFAULT 0,
            tokens_out INTEGER NOT NULL DEFAULT 0,
            cost_usd NUMERIC(12,6) NOT NULL DEFAULT 0,
            latency_ms INTEGER,
            jobshout_task_id VARCHAR(64),
            jobshout_run_id VARCHAR(64),
            jobshout_execution_id VARCHAR(64),
            triggered_by_user_uuid VARCHAR(255),
            started_at TIMESTAMPTZ,
            finished_at TIMESTAMPTZ,
            created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
            updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
        )
    ]])
    db.query("CREATE INDEX IF NOT EXISTS idx_pd_agent_runs_task ON property_deals_agent_runs (namespace_id, task_uuid, created_at DESC)")
    db.query("CREATE INDEX IF NOT EXISTS idx_pd_agent_runs_cost ON property_deals_agent_runs (namespace_id, created_at)")
    db.query([[
        CREATE INDEX IF NOT EXISTS idx_pd_agent_runs_jobshout ON property_deals_agent_runs (jobshout_execution_id)
        WHERE jobshout_execution_id IS NOT NULL
    ]])
    same_namespace("property_deals_agent_runs",
        { "task_uuid", "kanban_tasks", "deal_uuid", "property_deals_deals" })

    -- Nothing leaves the system without one of these being approved (hard rule 6).
    -- `decisions` is the append-only list of { user_uuid, decision, note, at,
    -- payload_sha256 }; two_person needs two different approvers.
    db.query([[
        CREATE TABLE IF NOT EXISTS property_deals_approvals (
            id BIGSERIAL PRIMARY KEY,
            uuid UUID NOT NULL UNIQUE DEFAULT gen_random_uuid(),
            namespace_id INTEGER NOT NULL REFERENCES namespaces(id) ON DELETE CASCADE,
            subject_type VARCHAR(30) NOT NULL CHECK (subject_type IN ('agent_draft', 'chase', 'booking',
                'compliance_close', 'offer', 'deal_pack', 'stage_gate', 'other')),
            action VARCHAR(40) NOT NULL,
            agent_run_uuid UUID REFERENCES property_deals_agent_runs(uuid) ON DELETE SET NULL,
            task_uuid VARCHAR(255) REFERENCES kanban_tasks(uuid) ON DELETE SET NULL,
            deal_uuid UUID REFERENCES property_deals_deals(uuid) ON DELETE CASCADE,
            title VARCHAR(255) NOT NULL,
            payload JSONB NOT NULL DEFAULT '{}',
            payload_version INTEGER NOT NULL DEFAULT 1,
            payload_sha256 VARCHAR(64),
            original_payload JSONB,
            rule VARCHAR(20) NOT NULL DEFAULT 'any_operator'
                CHECK (rule IN ('any_operator', 'manager', 'two_person')),
            status VARCHAR(20) NOT NULL DEFAULT 'pending' CHECK (status IN ('pending', 'approved', 'rejected',
                'cancelled', 'executed', 'failed')),
            requested_by_user_uuid VARCHAR(255),
            requested_by_agent VARCHAR(80),
            decisions JSONB NOT NULL DEFAULT '[]',
            decided_at TIMESTAMPTZ,
            executed_at TIMESTAMPTZ,
            execution_result JSONB,
            jobshout_approval_id VARCHAR(64),
            expires_at TIMESTAMPTZ,
            created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
            updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
        )
    ]])
    db.query([[
        CREATE INDEX IF NOT EXISTS idx_pd_approvals_pending ON property_deals_approvals (namespace_id, created_at)
        WHERE status = 'pending'
    ]])
    db.query("CREATE INDEX IF NOT EXISTS idx_pd_approvals_deal ON property_deals_approvals (namespace_id, deal_uuid)")
    same_namespace("property_deals_approvals", {
        "agent_run_uuid", "property_deals_agent_runs", "task_uuid", "kanban_tasks", "deal_uuid", "property_deals_deals",
    })
    for _, t in ipairs({ "property_deals_chases", "property_deals_bookings" }) do
        db.query(([[
            DO $$ BEGIN
                ALTER TABLE %s ADD CONSTRAINT %s_approval_fk FOREIGN KEY (approval_uuid)
                    REFERENCES property_deals_approvals(uuid) ON DELETE SET NULL;
            EXCEPTION WHEN duplicate_object THEN NULL;
            END $$
        ]]):format(t, t))
    end

    -- Property <-> buyer profile score (SPEC §3.7).
    db.query([[
        CREATE TABLE IF NOT EXISTS property_deals_matches (
            id BIGSERIAL PRIMARY KEY,
            uuid UUID NOT NULL UNIQUE DEFAULT gen_random_uuid(),
            namespace_id INTEGER NOT NULL REFERENCES namespaces(id) ON DELETE CASCADE,
            property_uuid UUID NOT NULL REFERENCES property_deals_properties(uuid) ON DELETE CASCADE,
            buyer_profile_uuid UUID NOT NULL REFERENCES property_deals_buyer_profiles(uuid) ON DELETE CASCADE,
            score NUMERIC(5,2) NOT NULL DEFAULT 0 CHECK (score BETWEEN 0 AND 100),
            breakdown JSONB NOT NULL DEFAULT '{}',
            status VARCHAR(20) NOT NULL DEFAULT 'suggested'
                CHECK (status IN ('suggested', 'sent', 'interested', 'declined')),
            sent_at TIMESTAMPTZ,
            approval_uuid UUID REFERENCES property_deals_approvals(uuid) ON DELETE SET NULL,
            computed_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
            created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
            updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
            UNIQUE (property_uuid, buyer_profile_uuid)
        )
    ]])
    db.query("CREATE INDEX IF NOT EXISTS idx_pd_matches_property ON property_deals_matches (namespace_id, property_uuid, score DESC)")
    db.query("CREATE INDEX IF NOT EXISTS idx_pd_matches_buyer ON property_deals_matches (namespace_id, buyer_profile_uuid, score DESC)")
    same_namespace("property_deals_matches", {
        "property_uuid", "property_deals_properties", "buyer_profile_uuid", "property_deals_buyer_profiles",
        "approval_uuid", "property_deals_approvals",
    })

    -- Non-working days per workspace (seeded from the built-in UK calendar on
    -- setup; editable, so another country is just different rows).
    db.query([[
        CREATE TABLE IF NOT EXISTS property_deals_holidays (
            id BIGSERIAL PRIMARY KEY,
            uuid UUID NOT NULL UNIQUE DEFAULT gen_random_uuid(),
            namespace_id INTEGER NOT NULL REFERENCES namespaces(id) ON DELETE CASCADE,
            jurisdiction VARCHAR(40) NOT NULL,
            holiday_date DATE NOT NULL,
            name VARCHAR(120) NOT NULL,
            created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
            updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
            UNIQUE (namespace_id, jurisdiction, holiday_date)
        )
    ]])

    -- Plugin state per workspace: where its kanban project lives, when it was set up.
    db.query([[
        CREATE TABLE IF NOT EXISTS property_deals_workspaces (
            id BIGSERIAL PRIMARY KEY,
            uuid UUID NOT NULL UNIQUE DEFAULT gen_random_uuid(),
            namespace_id INTEGER NOT NULL UNIQUE REFERENCES namespaces(id) ON DELETE CASCADE,
            kanban_project_uuid VARCHAR(255) REFERENCES kanban_projects(uuid) ON DELETE SET NULL,
            kanban_board_uuid VARCHAR(255) REFERENCES kanban_boards(uuid) ON DELETE SET NULL,
            setup_at TIMESTAMPTZ,
            setup_by_user_uuid VARCHAR(255),
            created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
            updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
        )
    ]])
    same_namespace("property_deals_workspaces", { "kanban_project_uuid", "kanban_projects" })
end
