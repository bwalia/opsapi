-- Phase 0 core schema: campaigns, deliveries, consent, suppression, lists, templates.
-- Idempotent CREATE IF NOT EXISTS. Every table is namespace-scoped.
return function(schema, db)
    db.query([[
        CREATE TABLE IF NOT EXISTS mkt_lists (
            id BIGSERIAL PRIMARY KEY,
            uuid UUID NOT NULL UNIQUE DEFAULT gen_random_uuid(),
            namespace_id BIGINT NOT NULL REFERENCES namespaces(id) ON DELETE CASCADE,
            name VARCHAR(255) NOT NULL,
            description TEXT,
            list_type VARCHAR(32) NOT NULL DEFAULT 'static',
            segment_rule JSONB NOT NULL DEFAULT '{}',
            channel VARCHAR(32),
            created_by UUID,
            created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
            updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
            CONSTRAINT mkt_lists_type_chk CHECK (list_type IN ('static', 'dynamic'))
        )
    ]])
    db.query("CREATE INDEX IF NOT EXISTS idx_mkt_lists_ns ON mkt_lists (namespace_id, id DESC)")

    db.query([[
        CREATE TABLE IF NOT EXISTS mkt_list_members (
            id BIGSERIAL PRIMARY KEY,
            uuid UUID NOT NULL UNIQUE DEFAULT gen_random_uuid(),
            namespace_id BIGINT NOT NULL REFERENCES namespaces(id) ON DELETE CASCADE,
            list_id BIGINT NOT NULL REFERENCES mkt_lists(id) ON DELETE CASCADE,
            contact_uuid TEXT NOT NULL,
            source VARCHAR(64) NOT NULL DEFAULT 'manual',
            added_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
            removed_at TIMESTAMPTZ,
            UNIQUE (namespace_id, list_id, contact_uuid)
        )
    ]])
    db.query("CREATE INDEX IF NOT EXISTS idx_mkt_list_members_list ON mkt_list_members (namespace_id, list_id) WHERE removed_at IS NULL")
    db.query("CREATE INDEX IF NOT EXISTS idx_mkt_list_members_contact ON mkt_list_members (namespace_id, contact_uuid)")

    db.query([[
        CREATE TABLE IF NOT EXISTS mkt_templates (
            id BIGSERIAL PRIMARY KEY,
            uuid UUID NOT NULL UNIQUE DEFAULT gen_random_uuid(),
            namespace_id BIGINT NOT NULL REFERENCES namespaces(id) ON DELETE CASCADE,
            name VARCHAR(255) NOT NULL,
            channel VARCHAR(32) NOT NULL DEFAULT 'email',
            subject VARCHAR(998),
            preview_text VARCHAR(255),
            body_html TEXT,
            body_text TEXT,
            status VARCHAR(32) NOT NULL DEFAULT 'draft',
            version INTEGER NOT NULL DEFAULT 1,
            parent_uuid UUID,
            created_by UUID,
            published_at TIMESTAMPTZ,
            created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
            updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
            CONSTRAINT mkt_templates_channel_chk CHECK (channel IN ('email', 'sms', 'push', 'webhook')),
            CONSTRAINT mkt_templates_status_chk CHECK (status IN ('draft', 'published', 'archived'))
        )
    ]])
    db.query("CREATE INDEX IF NOT EXISTS idx_mkt_templates_ns ON mkt_templates (namespace_id, channel, status)")

    db.query([[
        CREATE TABLE IF NOT EXISTS mkt_campaigns (
            id BIGSERIAL PRIMARY KEY,
            uuid UUID NOT NULL UNIQUE DEFAULT gen_random_uuid(),
            namespace_id BIGINT NOT NULL REFERENCES namespaces(id) ON DELETE CASCADE,
            name VARCHAR(255) NOT NULL,
            objective TEXT,
            channel VARCHAR(32) NOT NULL DEFAULT 'email',
            message_type VARCHAR(32) NOT NULL DEFAULT 'marketing',
            status VARCHAR(32) NOT NULL DEFAULT 'draft',
            list_id BIGINT REFERENCES mkt_lists(id) ON DELETE SET NULL,
            template_id BIGINT REFERENCES mkt_templates(id) ON DELETE SET NULL,
            subject VARCHAR(998),
            preview_text VARCHAR(255),
            body_html TEXT,
            body_text TEXT,
            from_email VARCHAR(255),
            from_name VARCHAR(255),
            reply_to VARCHAR(255),
            scheduled_at TIMESTAMPTZ,
            started_at TIMESTAMPTZ,
            completed_at TIMESTAMPTZ,
            approval_required BOOLEAN NOT NULL DEFAULT false,
            approved_by UUID,
            approved_at TIMESTAMPTZ,
            exclusion_rules JSONB NOT NULL DEFAULT '{}',
            ab_config JSONB NOT NULL DEFAULT '{}',
            created_by UUID,
            created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
            updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
            CONSTRAINT mkt_campaigns_channel_chk CHECK (channel IN ('email', 'sms', 'push', 'webhook')),
            CONSTRAINT mkt_campaigns_msg_chk CHECK (message_type IN ('marketing', 'transactional', 'other')),
            CONSTRAINT mkt_campaigns_status_chk CHECK (status IN (
                'draft', 'validated', 'awaiting_approval', 'scheduled', 'sending',
                'completed', 'paused', 'cancelled', 'failed'
            ))
        )
    ]])
    db.query("CREATE INDEX IF NOT EXISTS idx_mkt_campaigns_ns ON mkt_campaigns (namespace_id, status, scheduled_at)")
    db.query("CREATE INDEX IF NOT EXISTS idx_mkt_campaigns_due ON mkt_campaigns (status, scheduled_at) WHERE status IN ('scheduled', 'sending')")

    db.query([[
        CREATE TABLE IF NOT EXISTS mkt_campaign_recipients (
            id BIGSERIAL PRIMARY KEY,
            uuid UUID NOT NULL UNIQUE DEFAULT gen_random_uuid(),
            namespace_id BIGINT NOT NULL REFERENCES namespaces(id) ON DELETE CASCADE,
            campaign_id BIGINT NOT NULL REFERENCES mkt_campaigns(id) ON DELETE CASCADE,
            contact_uuid TEXT NOT NULL,
            address VARCHAR(320) NOT NULL,
            display_name VARCHAR(255),
            merge_context JSONB NOT NULL DEFAULT '{}',
            eligibility_reason VARCHAR(128),
            excluded BOOLEAN NOT NULL DEFAULT false,
            created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
            UNIQUE (namespace_id, campaign_id, contact_uuid)
        )
    ]])
    db.query("CREATE INDEX IF NOT EXISTS idx_mkt_recip_campaign ON mkt_campaign_recipients (campaign_id) WHERE excluded = false")

    db.query([[
        CREATE TABLE IF NOT EXISTS mkt_deliveries (
            id BIGSERIAL PRIMARY KEY,
            uuid UUID NOT NULL UNIQUE DEFAULT gen_random_uuid(),
            namespace_id BIGINT NOT NULL REFERENCES namespaces(id) ON DELETE CASCADE,
            campaign_id BIGINT NOT NULL REFERENCES mkt_campaigns(id) ON DELETE CASCADE,
            recipient_id BIGINT REFERENCES mkt_campaign_recipients(id) ON DELETE SET NULL,
            contact_uuid TEXT NOT NULL,
            channel VARCHAR(32) NOT NULL,
            address VARCHAR(320) NOT NULL,
            attempt_key VARCHAR(64) NOT NULL DEFAULT '1',
            state VARCHAR(32) NOT NULL DEFAULT 'queued',
            provider_message_id VARCHAR(255),
            reason VARCHAR(255),
            subject VARCHAR(998),
            body_html TEXT,
            body_text TEXT,
            eligibility_reason VARCHAR(128),
            queued_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
            accepted_at TIMESTAMPTZ,
            delivered_at TIMESTAMPTZ,
            failed_at TIMESTAMPTZ,
            opened_at TIMESTAMPTZ,
            clicked_at TIMESTAMPTZ,
            created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
            updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
            UNIQUE (namespace_id, campaign_id, contact_uuid, channel, attempt_key),
            CONSTRAINT mkt_deliveries_state_chk CHECK (state IN (
                'queued', 'accepted', 'delivered', 'bounced', 'failed', 'skipped', 'unknown'
            ))
        )
    ]])
    db.query("CREATE INDEX IF NOT EXISTS idx_mkt_deliveries_claim ON mkt_deliveries (namespace_id, state, queued_at) WHERE state = 'queued'")
    db.query("CREATE INDEX IF NOT EXISTS idx_mkt_deliveries_campaign ON mkt_deliveries (campaign_id, state)")

    db.query([[
        CREATE TABLE IF NOT EXISTS mkt_suppressions (
            id BIGSERIAL PRIMARY KEY,
            uuid UUID NOT NULL UNIQUE DEFAULT gen_random_uuid(),
            namespace_id BIGINT NOT NULL REFERENCES namespaces(id) ON DELETE CASCADE,
            channel VARCHAR(32),
            address VARCHAR(320) NOT NULL,
            contact_uuid TEXT,
            reason VARCHAR(64) NOT NULL,
            source VARCHAR(64) NOT NULL DEFAULT 'manual',
            notes TEXT,
            created_by UUID,
            created_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
        )
    ]])
    db.query([[
        CREATE UNIQUE INDEX IF NOT EXISTS mkt_suppressions_ns_channel_addr_uidx
        ON mkt_suppressions (namespace_id, COALESCE(channel, ''), lower(address))
    ]])
    db.query("CREATE INDEX IF NOT EXISTS idx_mkt_suppressions_ns ON mkt_suppressions (namespace_id, channel)")

    db.query([[
        CREATE TABLE IF NOT EXISTS mkt_subscriptions (
            id BIGSERIAL PRIMARY KEY,
            uuid UUID NOT NULL UNIQUE DEFAULT gen_random_uuid(),
            namespace_id BIGINT NOT NULL REFERENCES namespaces(id) ON DELETE CASCADE,
            contact_uuid TEXT NOT NULL,
            channel VARCHAR(32) NOT NULL,
            list_id BIGINT REFERENCES mkt_lists(id) ON DELETE CASCADE,
            status VARCHAR(32) NOT NULL DEFAULT 'subscribed',
            legal_basis VARCHAR(64),
            source VARCHAR(64) NOT NULL DEFAULT 'manual',
            evidence TEXT,
            changed_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
            created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
            updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
            CONSTRAINT mkt_subs_status_chk CHECK (status IN ('subscribed', 'unsubscribed', 'pending'))
        )
    ]])
    db.query([[
        CREATE UNIQUE INDEX IF NOT EXISTS mkt_subscriptions_uidx
        ON mkt_subscriptions (namespace_id, contact_uuid, channel, COALESCE(list_id, 0))
    ]])
    db.query("CREATE INDEX IF NOT EXISTS idx_mkt_subs_contact ON mkt_subscriptions (namespace_id, contact_uuid, channel)")

    db.query([[
        CREATE TABLE IF NOT EXISTS mkt_subscription_events (
            id BIGSERIAL PRIMARY KEY,
            uuid UUID NOT NULL UNIQUE DEFAULT gen_random_uuid(),
            namespace_id BIGINT NOT NULL REFERENCES namespaces(id) ON DELETE CASCADE,
            contact_uuid TEXT NOT NULL,
            channel VARCHAR(32) NOT NULL,
            list_id BIGINT,
            previous_status VARCHAR(32),
            new_status VARCHAR(32) NOT NULL,
            source VARCHAR(64) NOT NULL,
            evidence TEXT,
            actor_uuid UUID,
            created_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
        )
    ]])
    db.query("CREATE INDEX IF NOT EXISTS idx_mkt_sub_events_ns ON mkt_subscription_events (namespace_id, contact_uuid, created_at DESC)")

    db.query([[
        CREATE TABLE IF NOT EXISTS mkt_eligibility_log (
            id BIGSERIAL PRIMARY KEY,
            namespace_id BIGINT NOT NULL REFERENCES namespaces(id) ON DELETE CASCADE,
            campaign_id BIGINT,
            contact_uuid TEXT,
            channel VARCHAR(32) NOT NULL,
            message_type VARCHAR(32) NOT NULL,
            allowed BOOLEAN NOT NULL,
            reason VARCHAR(128) NOT NULL,
            created_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
        )
    ]])
    db.query("CREATE INDEX IF NOT EXISTS idx_mkt_elig_ns ON mkt_eligibility_log (namespace_id, created_at DESC)")

    db.query([[
        CREATE TABLE IF NOT EXISTS mkt_tracking_events (
            id BIGSERIAL PRIMARY KEY,
            uuid UUID NOT NULL UNIQUE DEFAULT gen_random_uuid(),
            namespace_id BIGINT NOT NULL REFERENCES namespaces(id) ON DELETE CASCADE,
            delivery_id BIGINT REFERENCES mkt_deliveries(id) ON DELETE CASCADE,
            campaign_id BIGINT,
            contact_uuid TEXT,
            event_type VARCHAR(32) NOT NULL,
            url TEXT,
            ip_hash VARCHAR(64),
            user_agent VARCHAR(512),
            is_bot BOOLEAN NOT NULL DEFAULT false,
            is_estimated BOOLEAN NOT NULL DEFAULT false,
            created_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
        )
    ]])
    db.query("CREATE INDEX IF NOT EXISTS idx_mkt_tracking_delivery ON mkt_tracking_events (delivery_id, event_type)")
    db.query("CREATE INDEX IF NOT EXISTS idx_mkt_tracking_ns ON mkt_tracking_events (namespace_id, created_at DESC)")

    db.query([[
        CREATE TABLE IF NOT EXISTS mkt_merge_fields (
            id BIGSERIAL PRIMARY KEY,
            uuid UUID NOT NULL UNIQUE DEFAULT gen_random_uuid(),
            namespace_id BIGINT NOT NULL REFERENCES namespaces(id) ON DELETE CASCADE,
            key VARCHAR(128) NOT NULL,
            label VARCHAR(255) NOT NULL,
            field_type VARCHAR(32) NOT NULL DEFAULT 'string',
            source_path VARCHAR(255) NOT NULL,
            default_value TEXT,
            allow_html BOOLEAN NOT NULL DEFAULT false,
            created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
            UNIQUE (namespace_id, key)
        )
    ]])
end
