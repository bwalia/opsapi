-- Property PA hardening (review, Oct 2026). Idempotent: every statement can run again on a restored database.
--   * indexes for what the PA looks up per request, per run and per webhook
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
end
