local ChatDraftModel = require "models.ChatDraftModel"
local db = require("lapis.db")

local ChatDraftQueries = {}

-- Save or update a draft
function ChatDraftQueries.save(user_uuid, channel_uuid, content, parent_message_uuid)
    local existing = ChatDraftModel:find({
        user_uuid = user_uuid,
        channel_uuid = channel_uuid
    })

    if existing then
        return existing:update({
            content = content,
            parent_message_uuid = parent_message_uuid
        }, { returning = "*" })
    end

    return ChatDraftModel:create({
        user_uuid = user_uuid,
        channel_uuid = channel_uuid,
        content = content,
        parent_message_uuid = parent_message_uuid
    }, { returning = "*" })
end

-- Get draft for a channel
function ChatDraftQueries.get(user_uuid, channel_uuid)
    return ChatDraftModel:find({
        user_uuid = user_uuid,
        channel_uuid = channel_uuid
    })
end

-- Delete a draft
function ChatDraftQueries.delete(user_uuid, channel_uuid)
    local draft = ChatDraftModel:find({
        user_uuid = user_uuid,
        channel_uuid = channel_uuid
    })

    if not draft then
        return nil
    end

    return draft:delete()
end

-- Get all drafts for a user
function ChatDraftQueries.getAllByUser(user_uuid)
    local sql = [[
        SELECT d.*, c.name as channel_name, c.type as channel_type
        FROM chat_drafts d
        INNER JOIN chat_channels c ON c.uuid = d.channel_uuid
        WHERE d.user_uuid = ?
        ORDER BY d.updated_at DESC
    ]]

    return db.query(sql, user_uuid)
end

-- Delete all drafts for a user
function ChatDraftQueries.deleteAllByUser(user_uuid)
    local sql = "DELETE FROM chat_drafts WHERE user_uuid = ?"
    return db.query(sql, user_uuid)
end

-- Check if user has draft in channel
function ChatDraftQueries.hasDraft(user_uuid, channel_uuid)
    local draft = ChatDraftModel:find({
        user_uuid = user_uuid,
        channel_uuid = channel_uuid
    })
    return draft ~= nil and draft.content and draft.content ~= ""
end

return ChatDraftQueries
