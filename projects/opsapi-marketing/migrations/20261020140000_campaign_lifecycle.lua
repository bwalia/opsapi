-- Phase 3: A/B variant on deliveries, delivery budget, approval notes.
return function(schema, db)
    db.query([[
        ALTER TABLE mkt_campaigns
            ADD COLUMN IF NOT EXISTS max_deliveries INTEGER,
            ADD COLUMN IF NOT EXISTS approval_notes TEXT,
            ADD COLUMN IF NOT EXISTS rejected_reason TEXT,
            ADD COLUMN IF NOT EXISTS paused_at TIMESTAMPTZ,
            ADD COLUMN IF NOT EXISTS resume_status VARCHAR(32)
    ]])
    db.query([[
        ALTER TABLE mkt_deliveries
            ADD COLUMN IF NOT EXISTS variant_key VARCHAR(32)
    ]])
    db.query("CREATE INDEX IF NOT EXISTS idx_mkt_deliveries_variant ON mkt_deliveries (campaign_id, variant_key)")
end
