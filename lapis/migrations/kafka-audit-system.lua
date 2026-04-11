--[[
    Kafka & Audit System Migrations

    Tables:
    - audit_events: Immutable audit log for all entity changes and system events
    - kafka_outbox: Transactional outbox for reliable Kafka message delivery

    Uses raw SQL via db.query() with table_exists() guards.
]]

local db = require("lapis.db")

local function table_exists(name)
    local result = db.query("SELECT EXISTS (SELECT FROM information_schema.tables WHERE table_name = ?) as exists", name)
    return result and result[1] and result[1].exists
end

return {
    -- ========================================
    -- [1] Create audit_events table
    -- ========================================
    function()
        if table_exists("audit_events") then
            return
        end

        db.query([[
            CREATE TABLE audit_events (
                id BIGSERIAL PRIMARY KEY,
                uuid TEXT UNIQUE NOT NULL,
                namespace_id BIGINT NOT NULL DEFAULT 0,
                event_type TEXT NOT NULL,
                entity_type TEXT NOT NULL,
                entity_id TEXT,
                actor_user_uuid TEXT,
                actor_ip TEXT,
                old_values JSONB,
                new_values JSONB,
                metadata JSONB DEFAULT '{}',
                kafka_topic TEXT,
                kafka_offset BIGINT,
                kafka_partition INTEGER,
                created_at TIMESTAMP DEFAULT NOW()
            )
        ]])

        -- Composite index for namespace-scoped event queries
        db.query([[
            CREATE INDEX idx_audit_events_namespace_event_type
            ON audit_events (namespace_id, event_type)
        ]])

        -- Composite index for entity lookups
        db.query([[
            CREATE INDEX idx_audit_events_entity
            ON audit_events (entity_type, entity_id)
        ]])

        -- Index for actor lookups
        db.query([[
            CREATE INDEX idx_audit_events_actor
            ON audit_events (actor_user_uuid)
        ]])

        -- BRIN index for time-range queries (efficient for append-only data)
        db.query([[
            CREATE INDEX idx_audit_events_created_at_brin
            ON audit_events USING BRIN (created_at)
        ]])

        -- Index on event_type for filtering
        db.query([[
            CREATE INDEX idx_audit_events_event_type
            ON audit_events (event_type)
        ]])
    end,

    -- ========================================
    -- [2] Create kafka_outbox table
    -- ========================================
    function()
        if table_exists("kafka_outbox") then
            return
        end

        db.query([[
            CREATE TABLE kafka_outbox (
                id BIGSERIAL PRIMARY KEY,
                uuid TEXT UNIQUE NOT NULL,
                topic TEXT NOT NULL,
                key TEXT,
                payload JSONB NOT NULL,
                status TEXT DEFAULT 'pending' CHECK (status IN ('pending', 'sent', 'failed')),
                retry_count INTEGER DEFAULT 0,
                max_retries INTEGER DEFAULT 5,
                error_message TEXT,
                created_at TIMESTAMP DEFAULT NOW(),
                sent_at TIMESTAMP,
                failed_at TIMESTAMP,
                next_retry_at TIMESTAMP
            )
        ]])

        -- Composite index for outbox polling (find pending messages ready for retry)
        db.query([[
            CREATE INDEX idx_kafka_outbox_status_retry
            ON kafka_outbox (status, next_retry_at)
        ]])

        -- BRIN index for time-range queries
        db.query([[
            CREATE INDEX idx_kafka_outbox_created_at_brin
            ON kafka_outbox USING BRIN (created_at)
        ]])
    end,
}
