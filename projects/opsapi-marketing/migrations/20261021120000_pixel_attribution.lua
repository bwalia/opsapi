-- Phase 7: website pixel, visitor identity, conversion attribution, server-side forwarding,
-- per-campaign tracking config (UTM, link/open tracking, goal, attribution window).
return function(schema, db)
    db.query([[
        CREATE TABLE IF NOT EXISTS mkt_pixels (
            id BIGSERIAL PRIMARY KEY,
            uuid UUID NOT NULL UNIQUE DEFAULT gen_random_uuid(),
            namespace_id BIGINT NOT NULL REFERENCES namespaces(id) ON DELETE CASCADE,
            name VARCHAR(255) NOT NULL,
            public_key VARCHAR(64) NOT NULL UNIQUE,
            allowed_domains JSONB NOT NULL DEFAULT '[]',
            is_active BOOLEAN NOT NULL DEFAULT true,
            attribution_window_days INTEGER NOT NULL DEFAULT 7,
            last_event_at TIMESTAMPTZ,
            created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
            updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
            CONSTRAINT mkt_pixels_window_chk CHECK (attribution_window_days BETWEEN 1 AND 90)
        )
    ]])
    db.query("CREATE INDEX IF NOT EXISTS idx_mkt_pixels_ns ON mkt_pixels (namespace_id)")

    -- One row per browser (first-party cookie id); stitched to a CRM contact on
    -- email click-through or identify().
    db.query([[
        CREATE TABLE IF NOT EXISTS mkt_visitors (
            id BIGSERIAL PRIMARY KEY,
            namespace_id BIGINT NOT NULL REFERENCES namespaces(id) ON DELETE CASCADE,
            pixel_id BIGINT REFERENCES mkt_pixels(id) ON DELETE SET NULL,
            visitor_key VARCHAR(64) NOT NULL,
            contact_uuid TEXT,
            first_touch JSONB NOT NULL DEFAULT '{}',
            last_campaign_id BIGINT,
            last_delivery_id BIGINT,
            last_touch_at TIMESTAMPTZ,
            event_count INTEGER NOT NULL DEFAULT 0,
            first_seen_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
            last_seen_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
            UNIQUE (namespace_id, visitor_key)
        )
    ]])
    db.query("CREATE INDEX IF NOT EXISTS idx_mkt_visitors_contact ON mkt_visitors (namespace_id, contact_uuid)")

    db.query([[
        CREATE TABLE IF NOT EXISTS mkt_web_events (
            id BIGSERIAL PRIMARY KEY,
            uuid UUID NOT NULL UNIQUE DEFAULT gen_random_uuid(),
            namespace_id BIGINT NOT NULL REFERENCES namespaces(id) ON DELETE CASCADE,
            pixel_id BIGINT NOT NULL REFERENCES mkt_pixels(id) ON DELETE CASCADE,
            visitor_id BIGINT REFERENCES mkt_visitors(id) ON DELETE SET NULL,
            contact_uuid TEXT,
            event_name VARCHAR(64) NOT NULL,
            event_id VARCHAR(128),
            url TEXT,
            referrer TEXT,
            utm_source VARCHAR(255),
            utm_medium VARCHAR(255),
            utm_campaign VARCHAR(255),
            utm_content VARCHAR(255),
            utm_term VARCHAR(255),
            campaign_id BIGINT,
            delivery_id BIGINT,
            value NUMERIC(14,2),
            currency VARCHAR(3),
            order_id VARCHAR(128),
            properties JSONB NOT NULL DEFAULT '{}',
            ip_hash VARCHAR(64),
            user_agent VARCHAR(512),
            is_bot BOOLEAN NOT NULL DEFAULT false,
            is_test BOOLEAN NOT NULL DEFAULT false,
            is_conversion BOOLEAN NOT NULL DEFAULT false,
            forward_pending BOOLEAN NOT NULL DEFAULT false,
            created_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
        )
    ]])
    db.query([[
        CREATE INDEX IF NOT EXISTS idx_mkt_web_events_forward
        ON mkt_web_events (namespace_id, id) WHERE forward_pending
    ]])
    db.query([[
        CREATE UNIQUE INDEX IF NOT EXISTS mkt_web_events_dedupe
        ON mkt_web_events (pixel_id, event_id) WHERE event_id IS NOT NULL
    ]])
    db.query("CREATE INDEX IF NOT EXISTS idx_mkt_web_events_ns ON mkt_web_events (namespace_id, created_at DESC)")
    db.query("CREATE INDEX IF NOT EXISTS idx_mkt_web_events_pixel ON mkt_web_events (pixel_id, created_at DESC)")
    db.query("CREATE INDEX IF NOT EXISTS idx_mkt_web_events_campaign ON mkt_web_events (campaign_id, event_name)")

    db.query([[
        CREATE TABLE IF NOT EXISTS mkt_conversions (
            id BIGSERIAL PRIMARY KEY,
            uuid UUID NOT NULL UNIQUE DEFAULT gen_random_uuid(),
            namespace_id BIGINT NOT NULL REFERENCES namespaces(id) ON DELETE CASCADE,
            web_event_id BIGINT UNIQUE REFERENCES mkt_web_events(id) ON DELETE SET NULL,
            campaign_id BIGINT REFERENCES mkt_campaigns(id) ON DELETE SET NULL,
            delivery_id BIGINT REFERENCES mkt_deliveries(id) ON DELETE SET NULL,
            contact_uuid TEXT,
            visitor_id BIGINT,
            event_name VARCHAR(64) NOT NULL,
            value NUMERIC(14,2) NOT NULL DEFAULT 0,
            currency VARCHAR(3),
            order_id VARCHAR(128),
            model VARCHAR(32) NOT NULL DEFAULT 'last_click',
            touch_at TIMESTAMPTZ,
            created_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
        )
    ]])
    db.query([[
        CREATE UNIQUE INDEX IF NOT EXISTS mkt_conversions_order
        ON mkt_conversions (namespace_id, order_id) WHERE order_id IS NOT NULL
    ]])
    db.query("CREATE INDEX IF NOT EXISTS idx_mkt_conversions_campaign ON mkt_conversions (campaign_id, created_at)")
    db.query("CREATE INDEX IF NOT EXISTS idx_mkt_conversions_ns ON mkt_conversions (namespace_id, created_at DESC)")

    -- Server-side forwarding audit (Meta Conversions API, GA4 Measurement Protocol).
    db.query([[
        CREATE TABLE IF NOT EXISTS mkt_pixel_forwards (
            id BIGSERIAL PRIMARY KEY,
            namespace_id BIGINT NOT NULL REFERENCES namespaces(id) ON DELETE CASCADE,
            web_event_id BIGINT REFERENCES mkt_web_events(id) ON DELETE CASCADE,
            destination VARCHAR(32) NOT NULL,
            status VARCHAR(16) NOT NULL,
            http_status INTEGER,
            response TEXT,
            created_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
        )
    ]])
    db.query("CREATE INDEX IF NOT EXISTS idx_mkt_pixel_forwards_ns ON mkt_pixel_forwards (namespace_id, created_at DESC)")

    db.query([[
        ALTER TABLE mkt_deliveries
            ADD COLUMN IF NOT EXISTS converted_at TIMESTAMPTZ,
            ADD COLUMN IF NOT EXISTS conversion_value NUMERIC(14,2) NOT NULL DEFAULT 0
    ]])
    -- tracking = { track_opens, track_clicks, utm = { source, medium, campaign, content },
    --              goal_event, attribution_window_days }
    db.query([[
        ALTER TABLE mkt_campaigns
            ADD COLUMN IF NOT EXISTS tracking JSONB NOT NULL DEFAULT '{}'
    ]])
    db.query([[
        ALTER TABLE mkt_tracking_events
            ADD COLUMN IF NOT EXISTS bot_reason VARCHAR(64)
    ]])
    db.query("CREATE INDEX IF NOT EXISTS idx_mkt_tracking_campaign ON mkt_tracking_events (campaign_id, event_type)")
end
