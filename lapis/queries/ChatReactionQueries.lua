local ChatReactionModel = require "models.ChatReactionModel"
local Global = require "helper.global"
local db = require("lapis.db")

local ChatReactionQueries = {}

-- Add reaction to a message
function ChatReactionQueries.addReaction(message_uuid, user_uuid, emoji)
    -- Check if reaction already exists
    local existing = ChatReactionModel:find({
        message_uuid = message_uuid,
        user_uuid = user_uuid,
        emoji = emoji
    })

    if existing then
        return existing, "Reaction already exists"
    end

    return ChatReactionModel:create({
        uuid = Global.generateUUID(),
        message_uuid = message_uuid,
        user_uuid = user_uuid,
        emoji = emoji,
        created_at = db.raw("NOW()")
    }, { returning = "*" })
end

-- Remove reaction from a message
function ChatReactionQueries.removeReaction(message_uuid, user_uuid, emoji)
    local reaction = ChatReactionModel:find({
        message_uuid = message_uuid,
        user_uuid = user_uuid,
        emoji = emoji
    })

    if not reaction then
        return nil, "Reaction not found"
    end

    return reaction:delete()
end

-- Toggle reaction (add if not exists, remove if exists)
function ChatReactionQueries.toggleReaction(message_uuid, user_uuid, emoji)
    local existing = ChatReactionModel:find({
        message_uuid = message_uuid,
        user_uuid = user_uuid,
        emoji = emoji
    })

    if existing then
        existing:delete()
        return nil, "removed"
    end

    local reaction = ChatReactionModel:create({
        uuid = Global.generateUUID(),
        message_uuid = message_uuid,
        user_uuid = user_uuid,
        emoji = emoji,
        created_at = db.raw("NOW()")
    }, { returning = "*" })

    return reaction, "added"
end

-- Get all reactions for a message
function ChatReactionQueries.getByMessage(message_uuid)
    local sql = [[
        SELECT emoji, COUNT(*) as count,
               array_agg(user_uuid) as user_uuids
        FROM chat_message_reactions
        WHERE message_uuid = ?
        GROUP BY emoji
        ORDER BY count DESC
    ]]

    return db.query(sql, message_uuid)
end

-- Get reactions with user details
function ChatReactionQueries.getByMessageWithUsers(message_uuid)
    local sql = [[
        SELECT r.*, u.email, u.first_name, u.last_name, u.username
        FROM chat_message_reactions r
        INNER JOIN users u ON u.uuid = r.user_uuid
        WHERE r.message_uuid = ?
        ORDER BY r.created_at ASC
    ]]

    return db.query(sql, message_uuid)
end

-- Get users who reacted with a specific emoji
function ChatReactionQueries.getUsersByEmoji(message_uuid, emoji)
    local sql = [[
        SELECT r.*, u.email, u.first_name, u.last_name, u.username
        FROM chat_message_reactions r
        INNER JOIN users u ON u.uuid = r.user_uuid
        WHERE r.message_uuid = ? AND r.emoji = ?
        ORDER BY r.created_at ASC
    ]]

    return db.query(sql, message_uuid, emoji)
end

-- Remove all reactions from a message
function ChatReactionQueries.removeAllFromMessage(message_uuid)
    local sql = "DELETE FROM chat_message_reactions WHERE message_uuid = ?"
    return db.query(sql, message_uuid)
end

-- Get reaction count for a message
function ChatReactionQueries.countByMessage(message_uuid)
    local sql = [[
        SELECT COUNT(*) as total,
               COUNT(DISTINCT emoji) as unique_emojis
        FROM chat_message_reactions
        WHERE message_uuid = ?
    ]]

    local result = db.query(sql, message_uuid)
    if result and result[1] then
        return {
            total = tonumber(result[1].total),
            unique_emojis = tonumber(result[1].unique_emojis)
        }
    end
    return { total = 0, unique_emojis = 0 }
end

-- Check if user has reacted with specific emoji
function ChatReactionQueries.hasReacted(message_uuid, user_uuid, emoji)
    local reaction = ChatReactionModel:find({
        message_uuid = message_uuid,
        user_uuid = user_uuid,
        emoji = emoji
    })
    return reaction ~= nil
end

-- Get user's reactions in a channel
function ChatReactionQueries.getUserReactionsInChannel(channel_uuid, user_uuid)
    local sql = [[
        SELECT r.*, m.content as message_content
        FROM chat_message_reactions r
        INNER JOIN chat_messages m ON m.uuid = r.message_uuid
        WHERE m.channel_uuid = ? AND r.user_uuid = ?
        ORDER BY r.created_at DESC
    ]]

    return db.query(sql, channel_uuid, user_uuid)
end

-- Get most used emojis in a channel
function ChatReactionQueries.getMostUsedEmojis(channel_uuid, limit)
    limit = limit or 10

    local sql = [[
        SELECT r.emoji, COUNT(*) as count
        FROM chat_message_reactions r
        INNER JOIN chat_messages m ON m.uuid = r.message_uuid
        WHERE m.channel_uuid = ?
        GROUP BY r.emoji
        ORDER BY count DESC
        LIMIT ?
    ]]

    return db.query(sql, channel_uuid, limit)
end

return ChatReactionQueries
