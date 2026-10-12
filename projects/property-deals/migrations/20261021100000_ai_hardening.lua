-- AI hardening (review fixes):
--   * an enquiry can be owed by every party role an agent may name (broker, surveyor, estate agent too)
--   * an approval remembers each side effect already done (execution_steps), so a retry never sends twice
--   * one open agent run per task: a double click, or an email racing a click, starts one run
return function(schema, db)
    db.query([[ALTER TABLE property_deals_enquiries
        DROP CONSTRAINT IF EXISTS property_deals_enquiries_owner_party_check]])
    db.query([[
        ALTER TABLE property_deals_enquiries ADD CONSTRAINT property_deals_enquiries_owner_party_check
        CHECK (owner_party IN ('seller', 'buyer', 'buyer_solicitor', 'seller_solicitor', 'lender', 'broker',
            'surveyor', 'estate_agent', 'freeholder', 'managing_agent', 'council', 'other'))
    ]])

    db.query([[ALTER TABLE property_deals_approvals
        ADD COLUMN IF NOT EXISTS execution_steps JSONB NOT NULL DEFAULT '{}']])

    -- Duplicates from before the index can't block it: keep the newest open run per task.
    db.query([[
        UPDATE property_deals_agent_runs SET status = 'failed', error = 'superseded by a newer run',
            finished_at = NOW(), updated_at = NOW()
        WHERE id IN (SELECT id FROM (
            SELECT id, ROW_NUMBER() OVER (PARTITION BY namespace_id, task_uuid ORDER BY created_at DESC, id DESC) AS n
            FROM property_deals_agent_runs WHERE status IN ('queued', 'running') AND task_uuid IS NOT NULL) d
            WHERE n > 1)
    ]])
    db.query([[
        CREATE UNIQUE INDEX IF NOT EXISTS idx_pd_agent_runs_one_open
            ON property_deals_agent_runs (namespace_id, task_uuid)
        WHERE status IN ('queued', 'running') AND task_uuid IS NOT NULL
    ]])
end
