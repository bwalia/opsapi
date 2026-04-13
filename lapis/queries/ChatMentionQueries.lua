local ChatMentionModel = require "models.ChatMentionModel"
local Global = require "helper.global"
local db = require("lapis.db")

local ChatMentionQueries = {}

-- Create mention records for a message
function ChatMentionQueries.createMentions(message_uuid, channel_uuid, mentioned_by_uuid, mentioned_users, mention_type)
    mention_type = mention_type or "user"
    local created = {}

    for _, user_uuid in ipairs(mentioned_users) do
        local mention = ChatMentionModel:create({
            uuid = Global.generateUUID(),
            message_uuid = message_uuid,
            channel_uuid = channel_uuid,
            mentioned_user_uuid = user_uuid,
            mentioned_by_uuid = mentioned_by_uuid,
            mention_type = mention_type,
            created_at = db.raw("NOW()")
        }, { returning = "*" })

        if mention then
            table.insert(created, mention)
        end
    end

    return created
end

-- Get unread mentions for a user
function ChatMentionQueries.getUnreadMentions(user_uuid, params)
    local limit = params.limit or 50
    local offset = params.offset or 0

    local sql = [[
        SELECT mn.*, m.content, m.content_type, m.created_at as message_created_at,
               u.first_name as sender_first_name, u.last_name as sender_last_name,
               c.name as channel_name
        FROM chat_mentions mn
        INNER JOIN chat_messages m ON m.uuid = mn.message_uuid
        INNER JOIN users u ON u.uuid = mn.mentioned_by_uuid
        INNER JOIN chat_channels c ON c.uuid = mn.channel_uuid
        WHERE mn.mentioned_user_uuid = ?
          AND mn.is_read = false
          AND m.is_deleted = false
        ORDER BY mn.created_at DESC
        LIMIT ? OFFSET ?
    ]]

    return db.query(sql, user_uuid, limit, offset)
end

-- Get all mentions for a user
function ChatMentionQueries.getAllMentions(user_uuid, params)
    local limit = params.limit or 50
    local offset = params.offset or 0

    local sql = [[
        SELECT mn.*, m.content, m.content_type, m.created_at as message_created_at,
               u.first_name as sender_first_name, u.last_name as sender_last_name,
               c.name as channel_name
        FROM chat_mentions mn
        INNER JOIN chat_messages m ON m.uuid = mn.message_uuid
        INNER JOIN users u ON u.uuid = mn.mentioned_by_uuid
        INNER JOIN chat_channels c ON c.uuid = mn.channel_uuid
        WHERE mn.mentioned_user_uuid = ?
          AND m.is_deleted = false
        ORDER BY mn.created_at DESC
        LIMIT ? OFFSET ?
    ]]

    return db.query(sql, user_uuid, limit, offset)
end

-- Mark mention as read
function ChatMentionQueries.markAsRead(mention_uuid)
    local mention = ChatMentionModel:find({ uuid = mention_uuid })
    if not mention then return nil end
    return mention:update({ is_read = true }, { returning = "*" })
end

-- Mark all mentions in a channel as read
function ChatMentionQueries.markChannelAsRead(user_uuid, channel_uuid)
    local sql = [[
        UPDATE chat_mentions
        SET is_read = true
        WHERE mentioned_user_uuid = ?
          AND channel_uuid = ?
          AND is_read = false
        RETURNING *
    ]]
    return db.query(sql, user_uuid, channel_uuid)
end

-- Mark all mentions as read
function ChatMentionQueries.markAllAsRead(user_uuid)
    local sql = [[
        UPDATE chat_mentions
        SET is_read = true
        WHERE mentioned_user_uuid = ?
          AND is_read = false
        RETURNING *
    ]]
    return db.query(sql, user_uuid)
end

-- Count unread mentions
function ChatMentionQueries.countUnread(user_uuid)
    local sql = [[
        SELECT COUNT(*) as count
        FROM chat_mentions mn
        INNER JOIN chat_messages m ON m.uuid = mn.message_uuid
        WHERE mn.mentioned_user_uuid = ?
          AND mn.is_read = false
          AND m.is_deleted = false
    ]]

    local result = db.query(sql, user_uuid)
    if result and result[1] then
        return tonumber(result[1].count)
    end
    return 0
end

-- Get mentions for a specific message
function ChatMentionQueries.getByMessage(message_uuid)
    local sql = [[
        SELECT mn.*, u.first_name, u.last_name, u.username
        FROM chat_mentions mn
        INNER JOIN users u ON u.uuid = mn.mentioned_user_uuid
        WHERE mn.message_uuid = ?
        ORDER BY mn.created_at ASC
    ]]

    return db.query(sql, message_uuid)
end

-- Delete mentions for a message (when message is deleted)
function ChatMentionQueries.deleteByMessage(message_uuid)
    local sql = "DELETE FROM chat_mentions WHERE message_uuid = ?"
    return db.query(sql, message_uuid)
end

return ChatMentionQueries
