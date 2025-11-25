local ChatMessageModel = require "models.ChatMessageModel"
local Global = require "helper.global"
local db = require("lapis.db")
local cjson = require("cjson.safe")

local ChatMessageQueries = {}

-- Create a new message
function ChatMessageQueries.create(params)
    if not params.uuid then
        params.uuid = Global.generateUUID()
    end
    if not params.content_type then
        params.content_type = "text"
    end

    -- Encode mentions and attachments if they are tables
    if type(params.mentions) == "table" then
        params.mentions = cjson.encode(params.mentions)
    end
    if type(params.attachments) == "table" then
        params.attachments = cjson.encode(params.attachments)
    end
    if type(params.metadata) == "table" then
        params.metadata = cjson.encode(params.metadata)
    end

    return ChatMessageModel:create(params, { returning = "*" })
end

-- Get messages for a channel (paginated, newest first)
function ChatMessageQueries.getByChannel(channel_uuid, params)
    local limit = params.limit or 50
    local before = params.before -- message uuid to get messages before
    local after = params.after   -- message uuid to get messages after

    local sql
    local query_params

    if before then
        sql = [[
            SELECT m.*, u.email, u.first_name, u.last_name, u.username as sender_username
            FROM chat_messages m
            INNER JOIN users u ON u.uuid = m.user_uuid
            WHERE m.channel_uuid = ?
              AND m.is_deleted = false
              AND m.parent_message_uuid IS NULL
              AND m.created_at < (SELECT created_at FROM chat_messages WHERE uuid = ?)
            ORDER BY m.created_at DESC
            LIMIT ?
        ]]
        query_params = { channel_uuid, before, limit }
    elseif after then
        sql = [[
            SELECT m.*, u.email, u.first_name, u.last_name, u.username as sender_username
            FROM chat_messages m
            INNER JOIN users u ON u.uuid = m.user_uuid
            WHERE m.channel_uuid = ?
              AND m.is_deleted = false
              AND m.parent_message_uuid IS NULL
              AND m.created_at > (SELECT created_at FROM chat_messages WHERE uuid = ?)
            ORDER BY m.created_at ASC
            LIMIT ?
        ]]
        query_params = { channel_uuid, after, limit }
    else
        sql = [[
            SELECT m.*, u.email, u.first_name, u.last_name, u.username as sender_username
            FROM chat_messages m
            INNER JOIN users u ON u.uuid = m.user_uuid
            WHERE m.channel_uuid = ?
              AND m.is_deleted = false
              AND m.parent_message_uuid IS NULL
            ORDER BY m.created_at DESC
            LIMIT ?
        ]]
        query_params = { channel_uuid, limit }
    end

    local messages = db.query(sql, table.unpack(query_params))

    -- Get reactions for each message
    if messages and #messages > 0 then
        for _, msg in ipairs(messages) do
            msg.reactions = ChatMessageQueries.getReactions(msg.uuid)
            -- Parse JSON fields
            if msg.mentions then
                msg.mentions = cjson.decode(msg.mentions) or {}
            end
            if msg.attachments then
                msg.attachments = cjson.decode(msg.attachments) or {}
            end
            if msg.metadata then
                msg.metadata = cjson.decode(msg.metadata) or {}
            end
        end
    end

    return messages
end

-- Get single message by UUID
function ChatMessageQueries.show(uuid)
    local sql = [[
        SELECT m.*, u.email, u.first_name, u.last_name, u.username as sender_username
        FROM chat_messages m
        INNER JOIN users u ON u.uuid = m.user_uuid
        WHERE m.uuid = ?
    ]]

    local result = db.query(sql, uuid)
    if result and #result > 0 then
        local msg = result[1]
        msg.reactions = ChatMessageQueries.getReactions(msg.uuid)
        if msg.mentions then
            msg.mentions = cjson.decode(msg.mentions) or {}
        end
        if msg.attachments then
            msg.attachments = cjson.decode(msg.attachments) or {}
        end
        if msg.metadata then
            msg.metadata = cjson.decode(msg.metadata) or {}
        end
        return msg
    end
    return nil
end

-- Update message
function ChatMessageQueries.update(uuid, params)
    local record = ChatMessageModel:find({ uuid = uuid })
    if not record then return nil end

    -- Encode mentions and attachments if they are tables
    if type(params.mentions) == "table" then
        params.mentions = cjson.encode(params.mentions)
    end
    if type(params.attachments) == "table" then
        params.attachments = cjson.encode(params.attachments)
    end
    if type(params.metadata) == "table" then
        params.metadata = cjson.encode(params.metadata)
    end

    -- Mark as edited if content is being updated
    if params.content then
        params.is_edited = true
        params.edited_at = db.raw("NOW()")
    end

    return record:update(params, { returning = "*" })
end

-- Soft delete message
function ChatMessageQueries.softDelete(uuid)
    local record = ChatMessageModel:find({ uuid = uuid })
    if not record then return nil end
    return record:update({
        is_deleted = true,
        deleted_at = db.raw("NOW()")
    }, { returning = "*" })
end

-- Hard delete message
function ChatMessageQueries.destroy(uuid)
    local record = ChatMessageModel:find({ uuid = uuid })
    if not record then return nil end
    return record:delete()
end

-- Get thread replies
function ChatMessageQueries.getThread(parent_uuid, params)
    local limit = params.limit or 50
    local offset = params.offset or 0

    local sql = [[
        SELECT m.*, u.email, u.first_name, u.last_name, u.username as sender_username
        FROM chat_messages m
        INNER JOIN users u ON u.uuid = m.user_uuid
        WHERE m.parent_message_uuid = ? AND m.is_deleted = false
        ORDER BY m.created_at ASC
        LIMIT ? OFFSET ?
    ]]

    local replies = db.query(sql, parent_uuid, limit, offset)

    -- Get reactions for each reply
    if replies and #replies > 0 then
        for _, msg in ipairs(replies) do
            msg.reactions = ChatMessageQueries.getReactions(msg.uuid)
            if msg.mentions then
                msg.mentions = cjson.decode(msg.mentions) or {}
            end
            if msg.attachments then
                msg.attachments = cjson.decode(msg.attachments) or {}
            end
        end
    end

    -- Get parent message
    local parent = ChatMessageQueries.show(parent_uuid)

    -- Count total replies
    local count_sql = [[
        SELECT COUNT(*) as total
        FROM chat_messages
        WHERE parent_message_uuid = ? AND is_deleted = false
    ]]
    local count_result = db.query(count_sql, parent_uuid)
    local total = count_result and count_result[1] and count_result[1].total or 0

    return {
        parent = parent,
        replies = replies,
        total = tonumber(total)
    }
end

-- Update reply count on parent message
function ChatMessageQueries.updateReplyCount(parent_uuid)
    local sql = [[
        UPDATE chat_messages
        SET reply_count = (
            SELECT COUNT(*) FROM chat_messages
            WHERE parent_message_uuid = ? AND is_deleted = false
        ),
        updated_at = NOW()
        WHERE uuid = ?
    ]]
    return db.query(sql, parent_uuid, parent_uuid)
end

-- Get reactions for a message
function ChatMessageQueries.getReactions(message_uuid)
    local sql = [[
        SELECT emoji, COUNT(*) as count,
               array_agg(user_uuid) as user_uuids
        FROM chat_message_reactions
        WHERE message_uuid = ?
        GROUP BY emoji
        ORDER BY count DESC
    ]]

    local result = db.query(sql, message_uuid)
    return result or {}
end

-- Pin message
function ChatMessageQueries.pin(uuid)
    local record = ChatMessageModel:find({ uuid = uuid })
    if not record then return nil end
    return record:update({ is_pinned = true }, { returning = "*" })
end

-- Unpin message
function ChatMessageQueries.unpin(uuid)
    local record = ChatMessageModel:find({ uuid = uuid })
    if not record then return nil end
    return record:update({ is_pinned = false }, { returning = "*" })
end

-- Get pinned messages for a channel
function ChatMessageQueries.getPinned(channel_uuid)
    local sql = [[
        SELECT m.*, u.email, u.first_name, u.last_name, u.username as sender_username
        FROM chat_messages m
        INNER JOIN users u ON u.uuid = m.user_uuid
        WHERE m.channel_uuid = ? AND m.is_pinned = true AND m.is_deleted = false
        ORDER BY m.created_at DESC
    ]]

    return db.query(sql, channel_uuid)
end

-- Search messages in a channel
function ChatMessageQueries.search(channel_uuid, search_term, params)
    local limit = params.limit or 50
    local offset = params.offset or 0

    local sql = [[
        SELECT m.*, u.email, u.first_name, u.last_name, u.username as sender_username
        FROM chat_messages m
        INNER JOIN users u ON u.uuid = m.user_uuid
        WHERE m.channel_uuid = ?
          AND m.is_deleted = false
          AND m.content ILIKE ?
        ORDER BY m.created_at DESC
        LIMIT ? OFFSET ?
    ]]

    local search_pattern = "%" .. search_term .. "%"
    return db.query(sql, channel_uuid, search_pattern, limit, offset)
end

-- Get unread messages count for a user in a channel
function ChatMessageQueries.getUnreadCount(channel_uuid, user_uuid)
    local sql = [[
        SELECT COUNT(*) as count
        FROM chat_messages m
        INNER JOIN chat_channel_members cm ON cm.channel_uuid = m.channel_uuid
        WHERE m.channel_uuid = ?
          AND cm.user_uuid = ?
          AND cm.left_at IS NULL
          AND m.is_deleted = false
          AND m.created_at > COALESCE(cm.last_read_at, '1970-01-01')
    ]]

    local result = db.query(sql, channel_uuid, user_uuid)
    if result and result[1] then
        return tonumber(result[1].count)
    end
    return 0
end

-- Extract mentions from content (helper)
function ChatMessageQueries.extractMentions(content)
    local mentions = {}
    -- Pattern matches @username or @uuid format
    for mention in string.gmatch(content, "@([%w%-_]+)") do
        table.insert(mentions, mention)
    end
    return mentions
end

-- Create system message
function ChatMessageQueries.createSystemMessage(channel_uuid, content)
    return ChatMessageQueries.create({
        channel_uuid = channel_uuid,
        user_uuid = "system",
        content = content,
        content_type = "system"
    })
end

return ChatMessageQueries
