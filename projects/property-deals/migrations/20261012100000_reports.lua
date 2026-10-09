-- Phase 7: reports and hardening.
--   * property_deals_stage_history  one row per stage a deal entered (entered_at / left_at), written by
--     the workflow engine. Reports need exact time-per-stage; the generic audit log is asynchronous and
--     optional, so it can't be the source of truth for these numbers. Backfilled from current stages.
--   * an index for "completed deals in a period" (late days, conversion).
return function(schema, db)
    db.query([[
        CREATE TABLE IF NOT EXISTS property_deals_stage_history (
            id BIGSERIAL PRIMARY KEY,
            namespace_id INTEGER NOT NULL REFERENCES namespaces(id) ON DELETE CASCADE,
            deal_uuid UUID NOT NULL REFERENCES property_deals_deals(uuid) ON DELETE CASCADE,
            stage_key VARCHAR(80) NOT NULL,
            from_stage_key VARCHAR(80),
            entered_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
            left_at TIMESTAMPTZ,
            entered_by_user_uuid VARCHAR(255),
            CHECK (left_at IS NULL OR left_at >= entered_at)
        )
    ]])
    db.query("CREATE INDEX IF NOT EXISTS idx_pd_stage_history_deal ON property_deals_stage_history (deal_uuid, entered_at)")
    db.query("CREATE INDEX IF NOT EXISTS idx_pd_stage_history_ns ON property_deals_stage_history (namespace_id, stage_key, entered_at)")
    db.query([[
        CREATE UNIQUE INDEX IF NOT EXISTS idx_pd_stage_history_open ON property_deals_stage_history (deal_uuid)
        WHERE left_at IS NULL
    ]])
    db.query([[
        INSERT INTO property_deals_stage_history (namespace_id, deal_uuid, stage_key, entered_at, left_at)
        SELECT d.namespace_id, d.uuid, d.stage_key, COALESCE(d.stage_entered_at, d.created_at),
               CASE WHEN d.status IN ('completed', 'fell_through') THEN GREATEST(COALESCE(d.actual_completion_at, d.updated_at),
                    COALESCE(d.stage_entered_at, d.created_at)) END
        FROM property_deals_deals d
        WHERE NOT EXISTS (SELECT 1 FROM property_deals_stage_history h WHERE h.deal_uuid = d.uuid)
    ]])
    db.query([[
        CREATE INDEX IF NOT EXISTS idx_pd_deals_completed ON property_deals_deals (namespace_id, actual_completion_at)
        WHERE status = 'completed'
    ]])
end
