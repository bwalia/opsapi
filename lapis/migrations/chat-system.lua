local schema = require("lapis.db.schema")
local types = schema.types
local db = require("lapis.db")

return {
    -- Create chat_channels table
    [1] = function()
        schema.create_table("chat_channels", {
            { "id", types.serial },
            { "uuid", types.varchar({ unique = true, null = false }) },
            { "name", types.varchar({ null = false }) },
            { "description", types.text({ null = true }) },
            { "type", types.varchar({ default = "'public'" }) }, -- public, private, direct
            { "created_by", types.varchar({ null = false }) }, -- user uuid
            { "uuid_business_id", types.varchar({ null = true }) },
            { "linked_task_uuid", types.varchar({ null = true }) },
            { "linked_task_id", types.integer({ null = true }) },
            { "is_default", types.boolean({ default = false }) },
            { "is_archived", types.boolean({ default = false }) },
            { "avatar_url", types.varchar({ null = true }) },
            { "last_message_at", types.time({ null = true }) },
            { "created_at", types.time({ null = false }) },
            { "updated_at", types.time({ null = false }) },
            "PRIMARY KEY (id)"
        })
    end,

    -- Create indexes for chat_channels
    [2] = function()
        schema.create_index("chat_channels", "uuid")
        schema.create_index("chat_channels", "created_by")
        schema.create_index("chat_channels", "uuid_business_id")
        schema.create_index("chat_channels", "type")
        schema.create_index("chat_channels", "is_archived")
        schema.create_index("chat_channels", "linked_task_uuid")
    end,

    -- Create chat_channel_members table
    [3] = function()
        schema.create_table("chat_channel_members", {
            { "id", types.serial },
            { "uuid", types.varchar({ unique = true, null = false }) },
            { "channel_uuid", types.varchar({ null = false }) },
            { "user_uuid", types.varchar({ null = false }) },
            { "role", types.varchar({ default = "'member'" }) }, -- admin, moderator, member
            { "is_muted", types.boolean({ default = false }) },
            { "notification_preference", types.varchar({ default = "'all'" }) }, -- all, mentions, none
            { "joined_at", types.time({ null = false }) },
            { "left_at", types.time({ null = true }) },
            { "last_read_at", types.time({ null = true }) },
            { "created_at", types.time({ null = false }) },
            { "updated_at", types.time({ null = false }) },
            "PRIMARY KEY (id)",
            "UNIQUE(channel_uuid, user_uuid)"
        })
    end,

    -- Create indexes for chat_channel_members
    [4] = function()
        schema.create_index("chat_channel_members", "channel_uuid")
        schema.create_index("chat_channel_members", "user_uuid")
        schema.create_index("chat_channel_members", "role")
        db.query([[
            CREATE INDEX IF NOT EXISTS chat_channel_members_active_idx
            ON chat_channel_members (channel_uuid, user_uuid) WHERE left_at IS NULL
        ]])
    end,

    -- Create chat_messages table
    [5] = function()
        schema.create_table("chat_messages", {
            { "id", types.serial },
            { "uuid", types.varchar({ unique = true, null = false }) },
            { "channel_uuid", types.varchar({ null = false }) },
            { "user_uuid", types.varchar({ null = false }) },
            { "content", types.text({ null = false }) },
            { "content_type", types.varchar({ default = "'text'" }) }, -- text, code, markdown, system
            { "parent_message_uuid", types.varchar({ null = true }) }, -- for threads
            { "mentions", types.text({ null = true }) }, -- JSON array of user uuids
            { "attachments", types.text({ null = true }) }, -- JSON array of attachment objects
            { "metadata", types.text({ null = true }) }, -- JSON for additional data
            { "is_edited", types.boolean({ default = false }) },
            { "is_deleted", types.boolean({ default = false }) },
            { "is_pinned", types.boolean({ default = false }) },
            { "reply_count", types.integer({ default = 0 }) },
            { "edited_at", types.time({ null = true }) },
            { "deleted_at", types.time({ null = true }) },
            { "created_at", types.time({ null = false }) },
            { "updated_at", types.time({ null = false }) },
            "PRIMARY KEY (id)"
        })
    end,

    -- Create indexes for chat_messages
    [6] = function()
        schema.create_index("chat_messages", "uuid")
        schema.create_index("chat_messages", "channel_uuid")
        schema.create_index("chat_messages", "user_uuid")
        schema.create_index("chat_messages", "parent_message_uuid")
        schema.create_index("chat_messages", "is_pinned")
        db.query([[
            CREATE INDEX IF NOT EXISTS chat_messages_channel_created_idx
            ON chat_messages (channel_uuid, created_at DESC) WHERE is_deleted = false
        ]])
        db.query([[
            CREATE INDEX IF NOT EXISTS chat_messages_thread_idx
            ON chat_messages (parent_message_uuid, created_at ASC) WHERE parent_message_uuid IS NOT NULL
        ]])
    end,

    -- Create chat_message_reactions table
    [7] = function()
        schema.create_table("chat_message_reactions", {
            { "id", types.serial },
            { "uuid", types.varchar({ unique = true, null = false }) },
            { "message_uuid", types.varchar({ null = false }) },
            { "user_uuid", types.varchar({ null = false }) },
            { "emoji", types.varchar({ null = false }) },
            { "created_at", types.time({ null = false }) },
            "PRIMARY KEY (id)",
            "UNIQUE(message_uuid, user_uuid, emoji)"
        })
    end,

    -- Create indexes for chat_message_reactions
    [8] = function()
        schema.create_index("chat_message_reactions", "message_uuid")
        schema.create_index("chat_message_reactions", "user_uuid")
        schema.create_index("chat_message_reactions", "emoji")
    end,

    -- Create chat_read_receipts table (for tracking read status)
    [9] = function()
        schema.create_table("chat_read_receipts", {
            { "id", types.serial },
            { "channel_uuid", types.varchar({ null = false }) },
            { "user_uuid", types.varchar({ null = false }) },
            { "last_read_message_uuid", types.varchar({ null = true }) },
            { "last_read_at", types.time({ null = false }) },
            { "created_at", types.time({ null = false }) },
            { "updated_at", types.time({ null = false }) },
            "PRIMARY KEY (id)",
            "UNIQUE(channel_uuid, user_uuid)"
        })
    end,

    -- Create indexes for chat_read_receipts
    [10] = function()
        schema.create_index("chat_read_receipts", "channel_uuid")
        schema.create_index("chat_read_receipts", "user_uuid")
    end,

    -- Create chat_typing_indicators table (optional, for real-time typing)
    [11] = function()
        schema.create_table("chat_typing_indicators", {
            { "id", types.serial },
            { "channel_uuid", types.varchar({ null = false }) },
            { "user_uuid", types.varchar({ null = false }) },
            { "started_at", types.time({ null = false }) },
            "PRIMARY KEY (id)",
            "UNIQUE(channel_uuid, user_uuid)"
        })
    end,

    -- Create indexes for chat_typing_indicators
    [12] = function()
        schema.create_index("chat_typing_indicators", "channel_uuid")
    end,

    -- Add constraints
    [13] = function()
        pcall(function()
            db.query([[
                ALTER TABLE chat_channels
                ADD CONSTRAINT chat_channels_type_valid
                CHECK (type IN ('public', 'private', 'direct'))
            ]])
        end)
        pcall(function()
            db.query([[
                ALTER TABLE chat_channel_members
                ADD CONSTRAINT chat_channel_members_role_valid
                CHECK (role IN ('admin', 'moderator', 'member'))
            ]])
        end)
        pcall(function()
            db.query([[
                ALTER TABLE chat_channel_members
                ADD CONSTRAINT chat_channel_members_notification_valid
                CHECK (notification_preference IN ('all', 'mentions', 'none'))
            ]])
        end)
        pcall(function()
            db.query([[
                ALTER TABLE chat_messages
                ADD CONSTRAINT chat_messages_content_type_valid
                CHECK (content_type IN ('text', 'code', 'markdown', 'system'))
            ]])
        end)
    end,

    -- Add foreign key references (as comments for documentation, actual FK may depend on your setup)
    [14] = function()
        -- Note: Foreign keys to users table depend on your users table structure
        -- These are optional and can be enabled based on your database setup
        pcall(function()
            db.query([[
                ALTER TABLE chat_messages
                ADD CONSTRAINT chat_messages_channel_fk
                FOREIGN KEY (channel_uuid) REFERENCES chat_channels(uuid) ON DELETE CASCADE
            ]])
        end)
        pcall(function()
            db.query([[
                ALTER TABLE chat_channel_members
                ADD CONSTRAINT chat_channel_members_channel_fk
                FOREIGN KEY (channel_uuid) REFERENCES chat_channels(uuid) ON DELETE CASCADE
            ]])
        end)
        pcall(function()
            db.query([[
                ALTER TABLE chat_message_reactions
                ADD CONSTRAINT chat_message_reactions_message_fk
                FOREIGN KEY (message_uuid) REFERENCES chat_messages(uuid) ON DELETE CASCADE
            ]])
        end)
    end,

    -- Create chat_file_attachments table (for file uploads)
    [15] = function()
        schema.create_table("chat_file_attachments", {
            { "id", types.serial },
            { "uuid", types.varchar({ unique = true, null = false }) },
            { "message_uuid", types.varchar({ null = true }) }, -- null until attached to a message
            { "channel_uuid", types.varchar({ null = false }) },
            { "user_uuid", types.varchar({ null = false }) },
            { "file_name", types.varchar({ null = false }) },
            { "file_type", types.varchar({ null = false }) }, -- mime type
            { "file_size", types.integer({ null = false }) }, -- bytes
            { "file_url", types.text({ null = false }) },
            { "thumbnail_url", types.text({ null = true }) }, -- for images/videos
            { "width", types.integer({ null = true }) }, -- for images
            { "height", types.integer({ null = true }) }, -- for images
            { "duration", types.integer({ null = true }) }, -- for audio/video in seconds
            { "is_deleted", types.boolean({ default = false }) },
            { "created_at", types.time({ null = false }) },
            { "updated_at", types.time({ null = false }) },
            "PRIMARY KEY (id)"
        })
    end,

    -- Create indexes for chat_file_attachments
    [16] = function()
        schema.create_index("chat_file_attachments", "uuid")
        schema.create_index("chat_file_attachments", "message_uuid")
        schema.create_index("chat_file_attachments", "channel_uuid")
        schema.create_index("chat_file_attachments", "user_uuid")
    end,

    -- Create chat_user_presence table (online status tracking)
    [17] = function()
        schema.create_table("chat_user_presence", {
            { "id", types.serial },
            { "user_uuid", types.varchar({ unique = true, null = false }) },
            { "status", types.varchar({ default = "'offline'" }) }, -- online, away, dnd, offline
            { "status_text", types.varchar({ null = true }) }, -- custom status message
            { "status_emoji", types.varchar({ null = true }) }, -- status emoji
            { "last_seen_at", types.time({ null = true }) },
            { "last_active_at", types.time({ null = true }) },
            { "current_channel_uuid", types.varchar({ null = true }) }, -- channel user is currently viewing
            { "created_at", types.time({ null = false }) },
            { "updated_at", types.time({ null = false }) },
            "PRIMARY KEY (id)"
        })
    end,

    -- Create indexes for chat_user_presence
    [18] = function()
        schema.create_index("chat_user_presence", "user_uuid")
        schema.create_index("chat_user_presence", "status")
        schema.create_index("chat_user_presence", "last_seen_at")
    end,

    -- Create chat_bookmarks table (saved messages)
    [19] = function()
        schema.create_table("chat_bookmarks", {
            { "id", types.serial },
            { "uuid", types.varchar({ unique = true, null = false }) },
            { "user_uuid", types.varchar({ null = false }) },
            { "message_uuid", types.varchar({ null = false }) },
            { "note", types.text({ null = true }) }, -- optional note about bookmark
            { "created_at", types.time({ null = false }) },
            "PRIMARY KEY (id)",
            "UNIQUE(user_uuid, message_uuid)"
        })
    end,

    -- Create indexes for chat_bookmarks
    [20] = function()
        schema.create_index("chat_bookmarks", "user_uuid")
        schema.create_index("chat_bookmarks", "message_uuid")
    end,

    -- Create chat_drafts table (unsent message drafts)
    [21] = function()
        schema.create_table("chat_drafts", {
            { "id", types.serial },
            { "user_uuid", types.varchar({ null = false }) },
            { "channel_uuid", types.varchar({ null = false }) },
            { "content", types.text({ null = false }) },
            { "parent_message_uuid", types.varchar({ null = true }) }, -- for thread replies
            { "created_at", types.time({ null = false }) },
            { "updated_at", types.time({ null = false }) },
            "PRIMARY KEY (id)",
            "UNIQUE(user_uuid, channel_uuid)"
        })
    end,

    -- Create indexes for chat_drafts
    [22] = function()
        schema.create_index("chat_drafts", "user_uuid")
        schema.create_index("chat_drafts", "channel_uuid")
    end,

    -- Create chat_mentions table (for @mention notifications)
    [23] = function()
        schema.create_table("chat_mentions", {
            { "id", types.serial },
            { "uuid", types.varchar({ unique = true, null = false }) },
            { "message_uuid", types.varchar({ null = false }) },
            { "channel_uuid", types.varchar({ null = false }) },
            { "mentioned_user_uuid", types.varchar({ null = false }) },
            { "mentioned_by_uuid", types.varchar({ null = false }) },
            { "mention_type", types.varchar({ default = "'user'" }) }, -- user, channel, everyone, here
            { "is_read", types.boolean({ default = false }) },
            { "created_at", types.time({ null = false }) },
            "PRIMARY KEY (id)"
        })
    end,

    -- Create indexes for chat_mentions
    [24] = function()
        schema.create_index("chat_mentions", "message_uuid")
        schema.create_index("chat_mentions", "mentioned_user_uuid")
        schema.create_index("chat_mentions", "is_read")
        db.query([[
            CREATE INDEX IF NOT EXISTS chat_mentions_unread_idx
            ON chat_mentions (mentioned_user_uuid, created_at DESC) WHERE is_read = false
        ]])
    end,

    -- Create chat_channel_invites table (for private channel invitations)
    [25] = function()
        schema.create_table("chat_channel_invites", {
            { "id", types.serial },
            { "uuid", types.varchar({ unique = true, null = false }) },
            { "channel_uuid", types.varchar({ null = false }) },
            { "invited_user_uuid", types.varchar({ null = false }) },
            { "invited_by_uuid", types.varchar({ null = false }) },
            { "status", types.varchar({ default = "'pending'" }) }, -- pending, accepted, declined, expired
            { "message", types.text({ null = true }) }, -- optional invitation message
            { "expires_at", types.time({ null = true }) },
            { "responded_at", types.time({ null = true }) },
            { "created_at", types.time({ null = false }) },
            { "updated_at", types.time({ null = false }) },
            "PRIMARY KEY (id)"
        })
    end,

    -- Create indexes for chat_channel_invites
    [26] = function()
        schema.create_index("chat_channel_invites", "channel_uuid")
        schema.create_index("chat_channel_invites", "invited_user_uuid")
        schema.create_index("chat_channel_invites", "status")
    end,

    -- Add presence constraint
    [27] = function()
        pcall(function()
            db.query([[
                ALTER TABLE chat_user_presence
                ADD CONSTRAINT chat_user_presence_status_valid
                CHECK (status IN ('online', 'away', 'dnd', 'offline'))
            ]])
        end)
        pcall(function()
            db.query([[
                ALTER TABLE chat_channel_invites
                ADD CONSTRAINT chat_channel_invites_status_valid
                CHECK (status IN ('pending', 'accepted', 'declined', 'expired'))
            ]])
        end)
        pcall(function()
            db.query([[
                ALTER TABLE chat_mentions
                ADD CONSTRAINT chat_mentions_type_valid
                CHECK (mention_type IN ('user', 'channel', 'everyone', 'here'))
            ]])
        end)
    end,

    -- Create function to auto-update message counts
    [28] = function()
        pcall(function()
            db.query([[
                CREATE OR REPLACE FUNCTION update_channel_last_message()
                RETURNS TRIGGER AS $$
                BEGIN
                    UPDATE chat_channels
                    SET last_message_at = NEW.created_at, updated_at = NOW()
                    WHERE uuid = NEW.channel_uuid;
                    RETURN NEW;
                END;
                $$ LANGUAGE plpgsql;
            ]])
        end)
        pcall(function()
            db.query([[
                CREATE TRIGGER chat_message_insert_trigger
                AFTER INSERT ON chat_messages
                FOR EACH ROW
                EXECUTE FUNCTION update_channel_last_message();
            ]])
        end)
    end,

    -- Create function to auto-update reply counts
    [29] = function()
        pcall(function()
            db.query([[
                CREATE OR REPLACE FUNCTION update_message_reply_count()
                RETURNS TRIGGER AS $$
                BEGIN
                    IF NEW.parent_message_uuid IS NOT NULL THEN
                        UPDATE chat_messages
                        SET reply_count = (
                            SELECT COUNT(*) FROM chat_messages
                            WHERE parent_message_uuid = NEW.parent_message_uuid
                            AND is_deleted = false
                        ),
                        updated_at = NOW()
                        WHERE uuid = NEW.parent_message_uuid;
                    END IF;
                    RETURN NEW;
                END;
                $$ LANGUAGE plpgsql;
            ]])
        end)
        pcall(function()
            db.query([[
                CREATE TRIGGER chat_reply_insert_trigger
                AFTER INSERT OR UPDATE ON chat_messages
                FOR EACH ROW
                EXECUTE FUNCTION update_message_reply_count();
            ]])
        end)
    end,

    -- Create view for unread message counts per user per channel
    [30] = function()
        pcall(function()
            db.query([[
                CREATE OR REPLACE VIEW chat_unread_counts AS
                SELECT
                    cm.user_uuid,
                    cm.channel_uuid,
                    c.name as channel_name,
                    COUNT(m.id) as unread_count
                FROM chat_channel_members cm
                JOIN chat_channels c ON c.uuid = cm.channel_uuid
                LEFT JOIN chat_messages m ON m.channel_uuid = cm.channel_uuid
                    AND m.is_deleted = false
                    AND m.created_at > COALESCE(cm.last_read_at, '1970-01-01'::timestamp)
                    AND m.user_uuid != cm.user_uuid
                WHERE cm.left_at IS NULL
                GROUP BY cm.user_uuid, cm.channel_uuid, c.name;
            ]])
        end)
    end,

    -- Fix default values that had extra quotes
    [31] = function()
        -- Fix notification_preference default
        pcall(function()
            db.query([[
                ALTER TABLE chat_channel_members
                ALTER COLUMN notification_preference SET DEFAULT 'all'
            ]])
        end)
        -- Fix any existing records with quoted values
        pcall(function()
            db.query([[
                UPDATE chat_channel_members
                SET notification_preference = 'all'
                WHERE notification_preference = '''all''' OR notification_preference IS NULL
            ]])
        end)
        -- Fix type default
        pcall(function()
            db.query([[
                ALTER TABLE chat_channels
                ALTER COLUMN type SET DEFAULT 'public'
            ]])
        end)
        -- Fix role default
        pcall(function()
            db.query([[
                ALTER TABLE chat_channel_members
                ALTER COLUMN role SET DEFAULT 'member'
            ]])
        end)
        -- Fix status default
        pcall(function()
            db.query([[
                ALTER TABLE chat_user_presence
                ALTER COLUMN status SET DEFAULT 'offline'
            ]])
        end)
        -- Fix content_type default
        pcall(function()
            db.query([[
                ALTER TABLE chat_messages
                ALTER COLUMN content_type SET DEFAULT 'text'
            ]])
        end)
        -- Fix invite status default
        pcall(function()
            db.query([[
                ALTER TABLE chat_channel_invites
                ALTER COLUMN status SET DEFAULT 'pending'
            ]])
        end)
        -- Fix mention_type default
        pcall(function()
            db.query([[
                ALTER TABLE chat_mentions
                ALTER COLUMN mention_type SET DEFAULT 'user'
            ]])
        end)
    end
}
