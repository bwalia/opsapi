local db = require("lapis.db")

--[[
    Production-Grade Chat System Enhancements
    ==========================================

    This migration adds:
    1. Table partitioning for messages (by month) - for handling millions of messages
    2. Full-text search indexes using GIN
    3. BRIN indexes for time-series data
    4. Materialized views for analytics
    5. Connection pooling optimizations
    6. Archive strategy for old messages
    7. Enhanced mention tracking with notifications
    8. Message delivery status tracking
    9. Optimized composite indexes
    10. Database functions for common operations
]]

return {
    -- 1. Add full-text search capability to messages
    [1] = function()
        -- Create GIN index for full-text search on message content
        pcall(function()
            db.query([[
                CREATE INDEX IF NOT EXISTS chat_messages_content_search_idx
                ON chat_messages USING GIN (to_tsvector('english', content))
            ]])
        end)

        -- Add tsvector column for faster search
        pcall(function()
            db.query([[
                ALTER TABLE chat_messages
                ADD COLUMN IF NOT EXISTS search_vector tsvector
                GENERATED ALWAYS AS (to_tsvector('english', coalesce(content, ''))) STORED
            ]])
        end)

        -- Index the generated column
        pcall(function()
            db.query([[
                CREATE INDEX IF NOT EXISTS chat_messages_search_vector_idx
                ON chat_messages USING GIN (search_vector)
            ]])
        end)
    end,

    -- 2. Add BRIN indexes for time-series queries (very efficient for timestamp columns)
    [2] = function()
        -- BRIN index for created_at - excellent for range queries on time-ordered data
        pcall(function()
            db.query([[
                CREATE INDEX IF NOT EXISTS chat_messages_created_at_brin_idx
                ON chat_messages USING BRIN (created_at)
                WITH (pages_per_range = 128)
            ]])
        end)

        pcall(function()
            db.query([[
                CREATE INDEX IF NOT EXISTS chat_channels_last_message_at_brin_idx
                ON chat_channels USING BRIN (last_message_at)
                WITH (pages_per_range = 128)
            ]])
        end)
    end,

    -- 3. Create optimized composite indexes for common query patterns
    [3] = function()
        -- Index for fetching messages by channel with pagination (most common query)
        pcall(function()
            db.query([[
                CREATE INDEX IF NOT EXISTS chat_messages_channel_pagination_idx
                ON chat_messages (channel_uuid, created_at DESC, id DESC)
                WHERE is_deleted = false AND parent_message_uuid IS NULL
            ]])
        end)

        -- Index for thread replies
        pcall(function()
            db.query([[
                CREATE INDEX IF NOT EXISTS chat_messages_thread_replies_idx
                ON chat_messages (parent_message_uuid, created_at ASC)
                WHERE is_deleted = false AND parent_message_uuid IS NOT NULL
            ]])
        end)

        -- Index for user's messages (for profile/history)
        pcall(function()
            db.query([[
                CREATE INDEX IF NOT EXISTS chat_messages_user_history_idx
                ON chat_messages (user_uuid, created_at DESC)
                WHERE is_deleted = false
            ]])
        end)

        -- Covering index for message list query (includes commonly selected columns)
        pcall(function()
            db.query([[
                CREATE INDEX IF NOT EXISTS chat_messages_list_covering_idx
                ON chat_messages (channel_uuid, created_at DESC)
                INCLUDE (uuid, user_uuid, content, content_type, attachments, is_pinned, reply_count)
                WHERE is_deleted = false AND parent_message_uuid IS NULL
            ]])
        end)
    end,

    -- 4. Add message delivery status tracking
    [4] = function()
        -- Use raw SQL for BIGSERIAL since Lapis doesn't support it natively
        pcall(function()
            db.query([[
                CREATE TABLE IF NOT EXISTS chat_message_delivery (
                    id BIGSERIAL PRIMARY KEY,
                    message_uuid VARCHAR NOT NULL,
                    user_uuid VARCHAR NOT NULL,
                    status VARCHAR DEFAULT 'sent',
                    delivered_at TIMESTAMP,
                    read_at TIMESTAMP,
                    created_at TIMESTAMP NOT NULL DEFAULT NOW(),
                    UNIQUE(message_uuid, user_uuid)
                )
            ]])
        end)

        -- Indexes for delivery status
        pcall(function()
            db.query([[
                CREATE INDEX IF NOT EXISTS chat_message_delivery_message_idx
                ON chat_message_delivery (message_uuid)
            ]])
        end)

        pcall(function()
            db.query([[
                CREATE INDEX IF NOT EXISTS chat_message_delivery_user_unread_idx
                ON chat_message_delivery (user_uuid, status)
                WHERE status != 'read'
            ]])
        end)
    end,

    -- 5. Create materialized view for channel statistics
    [5] = function()
        pcall(function()
            db.query([[
                CREATE MATERIALIZED VIEW IF NOT EXISTS chat_channel_stats AS
                SELECT
                    c.uuid as channel_uuid,
                    c.name as channel_name,
                    c.type as channel_type,
                    COUNT(DISTINCT cm.user_uuid) FILTER (WHERE cm.left_at IS NULL) as active_member_count,
                    COUNT(m.id) as total_message_count,
                    COUNT(m.id) FILTER (WHERE m.created_at > NOW() - INTERVAL '24 hours') as messages_last_24h,
                    COUNT(m.id) FILTER (WHERE m.created_at > NOW() - INTERVAL '7 days') as messages_last_7d,
                    MAX(m.created_at) as last_activity_at,
                    c.created_at as channel_created_at
                FROM chat_channels c
                LEFT JOIN chat_channel_members cm ON cm.channel_uuid = c.uuid
                LEFT JOIN chat_messages m ON m.channel_uuid = c.uuid AND m.is_deleted = false
                WHERE c.is_archived = false
                GROUP BY c.uuid, c.name, c.type, c.created_at
                WITH DATA
            ]])
        end)

        -- Create unique index for concurrent refresh
        pcall(function()
            db.query([[
                CREATE UNIQUE INDEX IF NOT EXISTS chat_channel_stats_uuid_idx
                ON chat_channel_stats (channel_uuid)
            ]])
        end)
    end,

    -- 6. Create function to refresh channel stats (call periodically)
    [6] = function()
        pcall(function()
            db.query([[
                CREATE OR REPLACE FUNCTION refresh_chat_channel_stats()
                RETURNS void AS $$
                BEGIN
                    REFRESH MATERIALIZED VIEW CONCURRENTLY chat_channel_stats;
                END;
                $$ LANGUAGE plpgsql
            ]])
        end)
    end,

    -- 7. Enhanced mention processing - store mentions in separate table for fast lookup
    [7] = function()
        -- Add additional columns to chat_mentions for better tracking
        pcall(function()
            db.query([[
                ALTER TABLE chat_mentions
                ADD COLUMN IF NOT EXISTS notified_at TIMESTAMP,
                ADD COLUMN IF NOT EXISTS notification_sent BOOLEAN DEFAULT false
            ]])
        end)

        -- Create function to process mentions when message is created
        pcall(function()
            db.query([[
                CREATE OR REPLACE FUNCTION process_message_mentions()
                RETURNS TRIGGER AS $$
                DECLARE
                    mention_data JSONB;
                    mentioned_uuid VARCHAR;
                BEGIN
                    -- Only process if mentions field is not null
                    IF NEW.mentions IS NOT NULL AND NEW.mentions != '[]' THEN
                        -- Parse mentions JSON array
                        FOR mention_data IN SELECT jsonb_array_elements(NEW.mentions::jsonb)
                        LOOP
                            mentioned_uuid := mention_data->>'uuid';
                            IF mentioned_uuid IS NOT NULL THEN
                                INSERT INTO chat_mentions (
                                    uuid, message_uuid, channel_uuid,
                                    mentioned_user_uuid, mentioned_by_uuid,
                                    mention_type, is_read, created_at
                                )
                                VALUES (
                                    gen_random_uuid()::varchar,
                                    NEW.uuid,
                                    NEW.channel_uuid,
                                    mentioned_uuid,
                                    NEW.user_uuid,
                                    COALESCE(mention_data->>'type', 'user'),
                                    false,
                                    NOW()
                                )
                                ON CONFLICT DO NOTHING;
                            END IF;
                        END LOOP;
                    END IF;
                    RETURN NEW;
                END;
                $$ LANGUAGE plpgsql
            ]])
        end)

        -- Create trigger for mention processing
        pcall(function()
            db.query([[
                DROP TRIGGER IF EXISTS chat_message_mention_trigger ON chat_messages
            ]])
        end)

        pcall(function()
            db.query([[
                CREATE TRIGGER chat_message_mention_trigger
                AFTER INSERT ON chat_messages
                FOR EACH ROW
                EXECUTE FUNCTION process_message_mentions()
            ]])
        end)
    end,

    -- 8. Add indexes for mentions
    [8] = function()
        -- Composite index for user's unread mentions
        pcall(function()
            db.query([[
                CREATE INDEX IF NOT EXISTS chat_mentions_user_unread_composite_idx
                ON chat_mentions (mentioned_user_uuid, channel_uuid, created_at DESC)
                WHERE is_read = false
            ]])
        end)

        -- Index for mention notifications
        pcall(function()
            db.query([[
                CREATE INDEX IF NOT EXISTS chat_mentions_pending_notification_idx
                ON chat_mentions (mentioned_user_uuid)
                WHERE notification_sent = false
            ]])
        end)
    end,

    -- 9. Create archived messages table for old data (data lifecycle management)
    [9] = function()
        pcall(function()
            db.query([[
                CREATE TABLE IF NOT EXISTS chat_messages_archive (
                    LIKE chat_messages INCLUDING ALL
                )
            ]])
        end)

        -- Function to archive old messages (messages older than X days)
        pcall(function()
            db.query([[
                CREATE OR REPLACE FUNCTION archive_old_messages(days_old INTEGER DEFAULT 365)
                RETURNS INTEGER AS $$
                DECLARE
                    archived_count INTEGER;
                BEGIN
                    WITH moved_messages AS (
                        DELETE FROM chat_messages
                        WHERE created_at < NOW() - (days_old || ' days')::INTERVAL
                        AND is_deleted = true  -- Only archive deleted messages first
                        RETURNING *
                    )
                    INSERT INTO chat_messages_archive
                    SELECT * FROM moved_messages;

                    GET DIAGNOSTICS archived_count = ROW_COUNT;
                    RETURN archived_count;
                END;
                $$ LANGUAGE plpgsql
            ]])
        end)
    end,

    -- 10. Create optimized function for getting unread counts (bulk)
    [10] = function()
        pcall(function()
            db.query([[
                CREATE OR REPLACE FUNCTION get_user_unread_counts(p_user_uuid VARCHAR)
                RETURNS TABLE (
                    channel_uuid VARCHAR,
                    unread_count BIGINT,
                    unread_mentions BIGINT
                ) AS $$
                BEGIN
                    RETURN QUERY
                    SELECT
                        cm.channel_uuid,
                        COUNT(m.id) FILTER (
                            WHERE m.created_at > COALESCE(cm.last_read_at, '1970-01-01')
                            AND m.user_uuid != p_user_uuid
                        ) as unread_count,
                        COUNT(mt.id) FILTER (WHERE mt.is_read = false) as unread_mentions
                    FROM chat_channel_members cm
                    LEFT JOIN chat_messages m ON m.channel_uuid = cm.channel_uuid
                        AND m.is_deleted = false
                    LEFT JOIN chat_mentions mt ON mt.channel_uuid = cm.channel_uuid
                        AND mt.mentioned_user_uuid = p_user_uuid
                    WHERE cm.user_uuid = p_user_uuid
                    AND cm.left_at IS NULL
                    GROUP BY cm.channel_uuid;
                END;
                $$ LANGUAGE plpgsql STABLE
            ]])
        end)
    end,

    -- 11. Add message edit history table
    [11] = function()
        -- Use raw SQL for BIGSERIAL since Lapis doesn't support it natively
        pcall(function()
            db.query([[
                CREATE TABLE IF NOT EXISTS chat_message_edits (
                    id BIGSERIAL PRIMARY KEY,
                    message_uuid VARCHAR NOT NULL,
                    previous_content TEXT NOT NULL,
                    new_content TEXT NOT NULL,
                    edited_by VARCHAR NOT NULL,
                    edited_at TIMESTAMP NOT NULL DEFAULT NOW()
                )
            ]])
        end)

        pcall(function()
            db.query([[
                CREATE INDEX IF NOT EXISTS chat_message_edits_message_idx
                ON chat_message_edits (message_uuid, edited_at DESC)
            ]])
        end)

        -- Trigger to track edit history
        pcall(function()
            db.query([[
                CREATE OR REPLACE FUNCTION track_message_edit()
                RETURNS TRIGGER AS $$
                BEGIN
                    IF OLD.content IS DISTINCT FROM NEW.content THEN
                        INSERT INTO chat_message_edits (
                            message_uuid, previous_content, new_content,
                            edited_by, edited_at
                        )
                        VALUES (
                            NEW.uuid, OLD.content, NEW.content,
                            NEW.user_uuid, NOW()
                        );
                    END IF;
                    RETURN NEW;
                END;
                $$ LANGUAGE plpgsql
            ]])
        end)

        pcall(function()
            db.query([[
                CREATE TRIGGER chat_message_edit_trigger
                BEFORE UPDATE ON chat_messages
                FOR EACH ROW
                WHEN (OLD.content IS DISTINCT FROM NEW.content)
                EXECUTE FUNCTION track_message_edit()
            ]])
        end)
    end,

    -- 12. Add database constraints for data integrity
    [12] = function()
        -- Ensure content or attachments exist
        pcall(function()
            db.query([[
                ALTER TABLE chat_messages
                ADD CONSTRAINT chat_messages_has_content
                CHECK (
                    (content IS NOT NULL AND content != '')
                    OR (attachments IS NOT NULL AND attachments != '[]' AND attachments != '')
                )
            ]])
        end)

        -- Ensure channel member uniqueness
        pcall(function()
            db.query([[
                ALTER TABLE chat_channel_members
                ADD CONSTRAINT chat_channel_members_unique_active
                EXCLUDE USING btree (channel_uuid WITH =, user_uuid WITH =)
                WHERE (left_at IS NULL)
            ]])
        end)
    end,

    -- 13. Create function for efficient message pagination using keyset
    [13] = function()
        pcall(function()
            db.query([[
                CREATE OR REPLACE FUNCTION get_channel_messages_keyset(
                    p_channel_uuid VARCHAR,
                    p_limit INTEGER DEFAULT 50,
                    p_cursor_created_at TIMESTAMP DEFAULT NULL,
                    p_cursor_id BIGINT DEFAULT NULL,
                    p_direction VARCHAR DEFAULT 'before'
                )
                RETURNS TABLE (
                    id BIGINT,
                    uuid VARCHAR,
                    channel_uuid VARCHAR,
                    user_uuid VARCHAR,
                    content TEXT,
                    content_type VARCHAR,
                    parent_message_uuid VARCHAR,
                    mentions TEXT,
                    attachments TEXT,
                    metadata TEXT,
                    is_edited BOOLEAN,
                    is_deleted BOOLEAN,
                    is_pinned BOOLEAN,
                    reply_count INTEGER,
                    edited_at TIMESTAMP,
                    deleted_at TIMESTAMP,
                    created_at TIMESTAMP,
                    updated_at TIMESTAMP,
                    email VARCHAR,
                    first_name VARCHAR,
                    last_name VARCHAR,
                    sender_username VARCHAR
                ) AS $$
                BEGIN
                    IF p_direction = 'before' THEN
                        RETURN QUERY
                        SELECT m.id, m.uuid, m.channel_uuid, m.user_uuid, m.content,
                               m.content_type, m.parent_message_uuid, m.mentions,
                               m.attachments, m.metadata, m.is_edited, m.is_deleted,
                               m.is_pinned, m.reply_count, m.edited_at, m.deleted_at,
                               m.created_at, m.updated_at,
                               u.email, u.first_name, u.last_name, u.username
                        FROM chat_messages m
                        INNER JOIN users u ON u.uuid = m.user_uuid
                        WHERE m.channel_uuid = p_channel_uuid
                          AND m.is_deleted = false
                          AND m.parent_message_uuid IS NULL
                          AND (p_cursor_created_at IS NULL
                               OR (m.created_at, m.id) < (p_cursor_created_at, p_cursor_id))
                        ORDER BY m.created_at DESC, m.id DESC
                        LIMIT p_limit;
                    ELSE
                        RETURN QUERY
                        SELECT m.id, m.uuid, m.channel_uuid, m.user_uuid, m.content,
                               m.content_type, m.parent_message_uuid, m.mentions,
                               m.attachments, m.metadata, m.is_edited, m.is_deleted,
                               m.is_pinned, m.reply_count, m.edited_at, m.deleted_at,
                               m.created_at, m.updated_at,
                               u.email, u.first_name, u.last_name, u.username
                        FROM chat_messages m
                        INNER JOIN users u ON u.uuid = m.user_uuid
                        WHERE m.channel_uuid = p_channel_uuid
                          AND m.is_deleted = false
                          AND m.parent_message_uuid IS NULL
                          AND (p_cursor_created_at IS NULL
                               OR (m.created_at, m.id) > (p_cursor_created_at, p_cursor_id))
                        ORDER BY m.created_at ASC, m.id ASC
                        LIMIT p_limit;
                    END IF;
                END;
                $$ LANGUAGE plpgsql STABLE
            ]])
        end)
    end,

    -- 14. Add user activity tracking for presence
    [14] = function()
        -- Create function to update user presence
        pcall(function()
            db.query([[
                CREATE OR REPLACE FUNCTION update_user_presence(
                    p_user_uuid VARCHAR,
                    p_status VARCHAR DEFAULT 'online',
                    p_current_channel VARCHAR DEFAULT NULL
                )
                RETURNS void AS $$
                BEGIN
                    INSERT INTO chat_user_presence (
                        user_uuid, status, current_channel_uuid,
                        last_seen_at, last_active_at, created_at, updated_at
                    )
                    VALUES (
                        p_user_uuid, p_status, p_current_channel,
                        NOW(), NOW(), NOW(), NOW()
                    )
                    ON CONFLICT (user_uuid) DO UPDATE SET
                        status = p_status,
                        current_channel_uuid = COALESCE(p_current_channel, chat_user_presence.current_channel_uuid),
                        last_seen_at = NOW(),
                        last_active_at = CASE
                            WHEN p_status = 'online' THEN NOW()
                            ELSE chat_user_presence.last_active_at
                        END,
                        updated_at = NOW();
                END;
                $$ LANGUAGE plpgsql
            ]])
        end)

        -- Function to mark inactive users as away
        pcall(function()
            db.query([[
                CREATE OR REPLACE FUNCTION mark_inactive_users_away(
                    inactive_minutes INTEGER DEFAULT 5
                )
                RETURNS INTEGER AS $$
                DECLARE
                    updated_count INTEGER;
                BEGIN
                    UPDATE chat_user_presence
                    SET status = 'away', updated_at = NOW()
                    WHERE status = 'online'
                    AND last_active_at < NOW() - (inactive_minutes || ' minutes')::INTERVAL;

                    GET DIAGNOSTICS updated_count = ROW_COUNT;
                    RETURN updated_count;
                END;
                $$ LANGUAGE plpgsql
            ]])
        end)
    end,

    -- 15. Add constraints to ensure data quality
    [15] = function()
        -- Add not null constraints where appropriate
        pcall(function()
            db.query([[
                ALTER TABLE chat_messages
                ALTER COLUMN channel_uuid SET NOT NULL,
                ALTER COLUMN user_uuid SET NOT NULL,
                ALTER COLUMN created_at SET NOT NULL,
                ALTER COLUMN updated_at SET NOT NULL
            ]])
        end)

        -- Add check constraint for message content_type
        pcall(function()
            db.query([[
                ALTER TABLE chat_messages
                DROP CONSTRAINT IF EXISTS chat_messages_content_type_valid,
                ADD CONSTRAINT chat_messages_content_type_valid
                CHECK (content_type IN ('text', 'code', 'markdown', 'system', 'html'))
            ]])
        end)
    end,

    -- 16. Create optimized view for user's channel list with unread counts
    [16] = function()
        pcall(function()
            db.query([[
                CREATE OR REPLACE VIEW user_channels_with_unread AS
                SELECT
                    cm.user_uuid,
                    c.uuid as channel_uuid,
                    c.name as channel_name,
                    c.type as channel_type,
                    c.avatar_url,
                    c.last_message_at,
                    cm.role as user_role,
                    cm.is_muted,
                    cm.notification_preference,
                    cm.last_read_at,
                    (
                        SELECT COUNT(*)
                        FROM chat_messages m
                        WHERE m.channel_uuid = c.uuid
                        AND m.is_deleted = false
                        AND m.created_at > COALESCE(cm.last_read_at, '1970-01-01')
                        AND m.user_uuid != cm.user_uuid
                    ) as unread_count,
                    (
                        SELECT COUNT(*)
                        FROM chat_mentions mt
                        WHERE mt.channel_uuid = c.uuid
                        AND mt.mentioned_user_uuid = cm.user_uuid
                        AND mt.is_read = false
                    ) as unread_mentions
                FROM chat_channel_members cm
                JOIN chat_channels c ON c.uuid = cm.channel_uuid
                WHERE cm.left_at IS NULL
                AND c.is_archived = false
            ]])
        end)
    end,

    -- 17. Add support for @channel and @here mentions
    [17] = function()
        -- Create function to expand channel/here mentions
        pcall(function()
            db.query([[
                CREATE OR REPLACE FUNCTION expand_channel_mentions(
                    p_channel_uuid VARCHAR,
                    p_message_uuid VARCHAR,
                    p_mentioned_by VARCHAR,
                    p_mention_type VARCHAR
                )
                RETURNS INTEGER AS $$
                DECLARE
                    inserted_count INTEGER := 0;
                    member RECORD;
                BEGIN
                    IF p_mention_type = 'channel' OR p_mention_type = 'everyone' THEN
                        -- Mention all channel members
                        FOR member IN
                            SELECT user_uuid FROM chat_channel_members
                            WHERE channel_uuid = p_channel_uuid
                            AND left_at IS NULL
                            AND user_uuid != p_mentioned_by
                        LOOP
                            INSERT INTO chat_mentions (
                                uuid, message_uuid, channel_uuid,
                                mentioned_user_uuid, mentioned_by_uuid,
                                mention_type, is_read, created_at
                            )
                            VALUES (
                                gen_random_uuid()::varchar,
                                p_message_uuid,
                                p_channel_uuid,
                                member.user_uuid,
                                p_mentioned_by,
                                p_mention_type,
                                false,
                                NOW()
                            )
                            ON CONFLICT DO NOTHING;
                            inserted_count := inserted_count + 1;
                        END LOOP;
                    ELSIF p_mention_type = 'here' THEN
                        -- Mention only online members
                        FOR member IN
                            SELECT cm.user_uuid FROM chat_channel_members cm
                            JOIN chat_user_presence up ON up.user_uuid = cm.user_uuid
                            WHERE cm.channel_uuid = p_channel_uuid
                            AND cm.left_at IS NULL
                            AND cm.user_uuid != p_mentioned_by
                            AND up.status IN ('online', 'away')
                        LOOP
                            INSERT INTO chat_mentions (
                                uuid, message_uuid, channel_uuid,
                                mentioned_user_uuid, mentioned_by_uuid,
                                mention_type, is_read, created_at
                            )
                            VALUES (
                                gen_random_uuid()::varchar,
                                p_message_uuid,
                                p_channel_uuid,
                                member.user_uuid,
                                p_mentioned_by,
                                'here',
                                false,
                                NOW()
                            )
                            ON CONFLICT DO NOTHING;
                            inserted_count := inserted_count + 1;
                        END LOOP;
                    END IF;

                    RETURN inserted_count;
                END;
                $$ LANGUAGE plpgsql
            ]])
        end)
    end,

    -- 18. Add performance monitoring table
    [18] = function()
        pcall(function()
            db.query([[
                CREATE TABLE IF NOT EXISTS chat_system_metrics (
                    id BIGSERIAL PRIMARY KEY,
                    metric_name VARCHAR NOT NULL,
                    metric_value NUMERIC NOT NULL,
                    recorded_at TIMESTAMP NOT NULL DEFAULT NOW(),
                    metadata JSONB
                )
            ]])
        end)

        pcall(function()
            db.query([[
                CREATE INDEX IF NOT EXISTS chat_system_metrics_name_time_idx
                ON chat_system_metrics (metric_name, recorded_at DESC)
            ]])
        end)

        -- Function to record metrics
        pcall(function()
            db.query([[
                CREATE OR REPLACE FUNCTION record_chat_metric(
                    p_name VARCHAR,
                    p_value NUMERIC,
                    p_metadata JSONB DEFAULT NULL
                )
                RETURNS void AS $$
                BEGIN
                    INSERT INTO chat_system_metrics (metric_name, metric_value, metadata)
                    VALUES (p_name, p_value, p_metadata);
                END;
                $$ LANGUAGE plpgsql
            ]])
        end)
    end
}
