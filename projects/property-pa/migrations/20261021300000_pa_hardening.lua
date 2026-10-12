-- Property PA hardening (review, Oct 2026). Idempotent: every statement can run again on a restored database.
--   * indexes for what the PA looks up per request, per run and per webhook
--   * pa_external_refs: each inbound email / GoHighLevel contact is imported once (a unique claim, not a lookup)
--   * pa_sync_state: where a GoHighLevel pull got to, so a big location carries on next run
--   * pa_consent: consent basis and opt-out per person (PRD §6), outside the core contacts table
return function(_, db)
    -- Today / Prepare / Manager Today read next actions, waiting changes and runs per opportunity; the JobShout
    -- webhook finds its run by JobShout's id before it knows the workspace. The task and run tables are Property
    -- Deals'; the columns are the PA's (opportunity_uuid) or only queried by it (provider 'jobshout-pa').
    db.query([[CREATE INDEX IF NOT EXISTS idx_pd_task_details_pa_opp ON property_deals_task_details
        (namespace_id, opportunity_uuid) WHERE opportunity_uuid IS NOT NULL]])
    db.query([[CREATE INDEX IF NOT EXISTS idx_pd_agent_runs_pa_run ON property_deals_agent_runs (jobshout_run_id)
        WHERE provider = 'jobshout-pa']])
    db.query([[CREATE INDEX IF NOT EXISTS idx_pd_agent_runs_pa_interaction ON property_deals_agent_runs
        (namespace_id, (input_snapshot ->> 'interaction_uuid')) WHERE provider = 'jobshout-pa']])
    db.query("CREATE INDEX IF NOT EXISTS idx_pa_pu_target ON pa_proposed_updates (namespace_id, target_uuid)")
    db.query([[CREATE INDEX IF NOT EXISTS idx_pa_pu_run ON pa_proposed_updates (namespace_id, run_ref)
        WHERE run_ref IS NOT NULL]])
    db.query([[CREATE INDEX IF NOT EXISTS idx_pa_facts_run ON pa_field_facts (namespace_id, run_ref)
        WHERE run_ref IS NOT NULL]])

    -- One row per (workspace, source, external id), claimed in the import's own transaction. In a PA table rather
    -- than a unique index on crm_activities / crm_contacts metadata, so core tables stay untouched.
    db.query([[
        CREATE TABLE IF NOT EXISTS pa_external_refs (
            id BIGSERIAL PRIMARY KEY,
            namespace_id INTEGER NOT NULL REFERENCES namespaces(id) ON DELETE CASCADE,
            source VARCHAR(20) NOT NULL,      -- mail (an inbound message) | ghl (a GoHighLevel contact)
            external_id VARCHAR(255) NOT NULL,
            record_uuid TEXT,                 -- the interaction / person it became; NULL = seen, not imported
            created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
            UNIQUE (namespace_id, source, external_id)
        )
    ]])
    -- What earlier imports marked in metadata (no "?" operator: lapis reads it as a placeholder).
    db.query([[
        INSERT INTO pa_external_refs (namespace_id, source, external_id, record_uuid)
        SELECT namespace_id, 'mail', metadata ->> 'inbound_message_uuid', MIN(uuid) FROM crm_activities
        WHERE metadata ->> 'inbound_message_uuid' IS NOT NULL GROUP BY 1, 3
        ON CONFLICT DO NOTHING
    ]])
    db.query([[
        INSERT INTO pa_external_refs (namespace_id, source, external_id, record_uuid)
        SELECT namespace_id, 'ghl', metadata ->> 'ghl_id', MIN(uuid) FROM crm_contacts
        WHERE metadata ->> 'ghl_id' IS NOT NULL AND deleted_at IS NULL GROUP BY 1, 3
        ON CONFLICT DO NOTHING
    ]])
    db.query([[
        CREATE TABLE IF NOT EXISTS pa_sync_state (
            namespace_id INTEGER NOT NULL REFERENCES namespaces(id) ON DELETE CASCADE,
            source VARCHAR(20) NOT NULL,
            cursor TEXT,                      -- where the pass under way stopped; NULL = none under way
            pass_started_at TIMESTAMPTZ,
            last_run_at TIMESTAMPTZ,
            last_result JSONB,
            PRIMARY KEY (namespace_id, source)
        )
    ]])

    db.query([[
        CREATE TABLE IF NOT EXISTS pa_consent (
            id BIGSERIAL PRIMARY KEY,
            namespace_id INTEGER NOT NULL REFERENCES namespaces(id) ON DELETE CASCADE,
            person_uuid TEXT NOT NULL REFERENCES crm_contacts(uuid) ON DELETE CASCADE,
            consent_basis VARCHAR(30) CHECK (consent_basis IN ('consent', 'contract', 'legitimate_interests',
                'legal_obligation')),
            opted_out_at TIMESTAMPTZ,
            source VARCHAR(20) NOT NULL DEFAULT 'human',  -- human | ghl
            updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
            UNIQUE (namespace_id, person_uuid)
        )
    ]])
    db.query("DROP TRIGGER IF EXISTS pa_consent_same_ns ON pa_consent")
    db.query([[CREATE TRIGGER pa_consent_same_ns BEFORE INSERT OR UPDATE ON pa_consent
        FOR EACH ROW EXECUTE FUNCTION property_pa_same_namespace('person_uuid', 'crm_contacts')]])
end
