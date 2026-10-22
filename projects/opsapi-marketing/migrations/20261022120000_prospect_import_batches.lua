-- Prospect import (CSV / XLSX / PDF of business contacts) and batched sending.
return function(schema, db)
    -- Evidence of where imported business contacts came from (who, when, which file).
    db.query([[
        CREATE TABLE IF NOT EXISTS mkt_list_imports (
            id BIGSERIAL PRIMARY KEY,
            uuid UUID NOT NULL UNIQUE DEFAULT gen_random_uuid(),
            namespace_id BIGINT NOT NULL REFERENCES namespaces(id) ON DELETE CASCADE,
            list_id BIGINT REFERENCES mkt_lists(id) ON DELETE SET NULL,
            file_name VARCHAR(255) NOT NULL,
            file_type VARCHAR(16) NOT NULL,
            source_note TEXT,
            legal_basis VARCHAR(64) NOT NULL,
            found INTEGER NOT NULL DEFAULT 0,
            imported INTEGER NOT NULL DEFAULT 0,
            created_contacts INTEGER NOT NULL DEFAULT 0,
            skipped JSONB NOT NULL DEFAULT '{}',
            created_by UUID,
            created_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
        )
    ]])
    db.query("CREATE INDEX IF NOT EXISTS idx_mkt_list_imports_ns ON mkt_list_imports (namespace_id, created_at DESC)")

    -- Batches: a delivery isn't sent before send_after (e.g. 400 now, 400 an hour later).
    db.query([[
        ALTER TABLE mkt_campaigns
            ADD COLUMN IF NOT EXISTS batch_size INTEGER,
            ADD COLUMN IF NOT EXISTS batch_interval_minutes INTEGER
    ]])
    db.query("ALTER TABLE mkt_deliveries ADD COLUMN IF NOT EXISTS send_after TIMESTAMPTZ")
    db.query([[
        CREATE INDEX IF NOT EXISTS idx_mkt_deliveries_due
        ON mkt_deliveries (namespace_id, send_after) WHERE state = 'queued'
    ]])
end
