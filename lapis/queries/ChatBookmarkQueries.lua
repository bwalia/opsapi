local ChatBookmarkModel = require "models.ChatBookmarkModel"
local Global = require "helper.global"
local db = require("lapis.db")

local ChatBookmarkQueries = {}

-- Create a bookmark
function ChatBookmarkQueries.create(user_uuid, message_uuid, note)
    -- Check if already bookmarked
    local existing = ChatBookmarkModel:find({
        user_uuid = user_uuid,
        message_uuid = message_uuid
    })

    if existing then
        -- Update note if provided
        if note then
            return existing:update({ note = note }, { returning = "*" })
        end
        return existing
    end

    return ChatBookmarkModel:create({
        uuid = Global.generateUUID(),
        user_uuid = user_uuid,
        message_uuid = message_uuid,
        note = note,
        created_at = db.raw("NOW()")
    }, { returning = "*" })
end

-- Remove a bookmark
function ChatBookmarkQueries.remove(user_uuid, message_uuid)
    local bookmark = ChatBookmarkModel:find({
        user_uuid = user_uuid,
        message_uuid = message_uuid
    })

    if not bookmark then
        return nil, "Bookmark not found"
    end

    return bookmark:delete()
end

-- Get user's bookmarks
function ChatBookmarkQueries.getByUser(user_uuid, params)
    local limit = params.limit or 50
    local offset = params.offset or 0

    local sql = [[
        SELECT b.*, m.content, m.content_type, m.channel_uuid, m.created_at as message_created_at,
               u.first_name as sender_first_name, u.last_name as sender_last_name,
               c.name as channel_name
        FROM chat_bookmarks b
        INNER JOIN chat_messages m ON m.uuid = b.message_uuid
        INNER JOIN users u ON u.uuid = m.user_uuid
        INNER JOIN chat_channels c ON c.uuid = m.channel_uuid
        WHERE b.user_uuid = ? AND m.is_deleted = false
        ORDER BY b.created_at DESC
        LIMIT ? OFFSET ?
    ]]

    return db.query(sql, user_uuid, limit, offset)
end

-- Check if message is bookmarked
function ChatBookmarkQueries.isBookmarked(user_uuid, message_uuid)
    local bookmark = ChatBookmarkModel:find({
        user_uuid = user_uuid,
        message_uuid = message_uuid
    })
    return bookmark ~= nil
end

-- Update bookmark note
function ChatBookmarkQueries.updateNote(user_uuid, message_uuid, note)
    local bookmark = ChatBookmarkModel:find({
        user_uuid = user_uuid,
        message_uuid = message_uuid
    })

    if not bookmark then
        return nil, "Bookmark not found"
    end

    return bookmark:update({ note = note }, { returning = "*" })
end

-- Count user's bookmarks
function ChatBookmarkQueries.countByUser(user_uuid)
    local sql = [[
        SELECT COUNT(*) as count
        FROM chat_bookmarks b
        INNER JOIN chat_messages m ON m.uuid = b.message_uuid
        WHERE b.user_uuid = ? AND m.is_deleted = false
    ]]

    local result = db.query(sql, user_uuid)
    if result and result[1] then
        return tonumber(result[1].count)
    end
    return 0
end

return ChatBookmarkQueries
