-- Phase 4–5: replies/conversations, derived analytics cache, AI action audit.
return function(schema, db)
    db.query([[
        CREATE TABLE IF NOT EXISTS mkt_replies (
            id BIGSERIAL PRIMARY KEY,
            uuid UUID NOT NULL UNIQUE DEFAULT gen_random_uuid(),
            namespace_id BIGINT NOT NULL REFERENCES namespaces(id) ON DELETE CASCADE,
            channel VARCHAR(32) NOT NULL,
            delivery_id BIGINT REFERENCES mkt_deliveries(id) ON DELETE SET NULL,
            campaign_id BIGINT REFERENCES mkt_campaigns(id) ON DELETE SET NULL,
            contact_uuid TEXT,
            address VARCHAR(320),
            classification VARCHAR(64) NOT NULL DEFAULT 'uncertain',
            confidence NUMERIC(4,3),
            subject TEXT,
            body_text TEXT,
            raw JSONB NOT NULL DEFAULT '{}',
            needs_human BOOLEAN NOT NULL DEFAULT false,
            classified_by VARCHAR(32) NOT NULL DEFAULT 'rules',
            created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
            updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
            CONSTRAINT mkt_replies_class_chk CHECK (classification IN (
                'interested', 'more_info', 'pricing', 'meeting', 'not_interested',
                'unsubscribe', 'out_of_office', 'complaint', 'bounce',
                'human_assist', 'uncertain'
            ))
        )
    ]])
    db.query("CREATE INDEX IF NOT EXISTS idx_mkt_replies_ns ON mkt_replies (namespace_id, created_at DESC)")
    db.query("CREATE INDEX IF NOT EXISTS idx_mkt_replies_campaign ON mkt_replies (campaign_id, classification)")

    db.query([[
        CREATE TABLE IF NOT EXISTS mkt_ai_actions (
            id BIGSERIAL PRIMARY KEY,
            uuid UUID NOT NULL UNIQUE DEFAULT gen_random_uuid(),
            namespace_id BIGINT NOT NULL REFERENCES namespaces(id) ON DELETE CASCADE,
            user_uuid TEXT,
            agent VARCHAR(64) NOT NULL,
            action VARCHAR(64) NOT NULL,
            status VARCHAR(32) NOT NULL DEFAULT 'proposed',
            input_summary TEXT,
            output_summary TEXT,
            campaign_uuid UUID,
            contact_uuid TEXT,
            requires_approval BOOLEAN NOT NULL DEFAULT true,
            approved_by TEXT,
            approved_at TIMESTAMPTZ,
            created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
            CONSTRAINT mkt_ai_actions_status_chk CHECK (status IN (
                'proposed', 'approved', 'rejected', 'executed', 'blocked'
            ))
        )
    ]])
    db.query("CREATE INDEX IF NOT EXISTS idx_mkt_ai_actions_ns ON mkt_ai_actions (namespace_id, created_at DESC)")

    -- Idempotency for inbound webhooks
    db.query([[
        CREATE TABLE IF NOT EXISTS mkt_webhook_receipts (
            id BIGSERIAL PRIMARY KEY,
            namespace_id BIGINT NOT NULL REFERENCES namespaces(id) ON DELETE CASCADE,
            provider VARCHAR(64) NOT NULL,
            external_id VARCHAR(255) NOT NULL,
            event_type VARCHAR(64),
            created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
            UNIQUE (namespace_id, provider, external_id)
        )
    ]])
end
