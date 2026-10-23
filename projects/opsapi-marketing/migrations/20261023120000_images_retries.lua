-- Email images (uploaded, served from a public URL) and resilient sending
-- (a 'sending' state while the provider call runs outside a transaction; retries).
return function(schema, db)
    db.query([[
        CREATE TABLE IF NOT EXISTS mkt_images (
            id BIGSERIAL PRIMARY KEY,
            uuid UUID NOT NULL UNIQUE DEFAULT gen_random_uuid(),
            namespace_id BIGINT NOT NULL REFERENCES namespaces(id) ON DELETE CASCADE,
            object_key VARCHAR(512) NOT NULL,
            bucket VARCHAR(128) NOT NULL,
            content_type VARCHAR(64) NOT NULL,
            ext VARCHAR(8) NOT NULL,
            size_bytes INTEGER NOT NULL,
            file_name VARCHAR(255),
            created_by UUID,
            created_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
        )
    ]])
    db.query("CREATE INDEX IF NOT EXISTS idx_mkt_images_ns ON mkt_images (namespace_id, created_at DESC)")

    db.query("ALTER TABLE mkt_deliveries ADD COLUMN IF NOT EXISTS attempts INTEGER NOT NULL DEFAULT 0")
    db.query("ALTER TABLE mkt_deliveries DROP CONSTRAINT IF EXISTS mkt_deliveries_state_chk")
    db.query([[
        ALTER TABLE mkt_deliveries ADD CONSTRAINT mkt_deliveries_state_chk CHECK (state IN (
            'queued', 'sending', 'accepted', 'delivered', 'bounced', 'failed', 'skipped', 'unknown'
        ))
    ]])
end
