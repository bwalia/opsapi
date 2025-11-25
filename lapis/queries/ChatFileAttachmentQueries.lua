local ChatFileAttachmentModel = require "models.ChatFileAttachmentModel"
local Global = require "helper.global"
local db = require("lapis.db")

local ChatFileAttachmentQueries = {}

-- Create a new file attachment
function ChatFileAttachmentQueries.create(params)
    if not params.uuid then
        params.uuid = Global.generateUUID()
    end
    return ChatFileAttachmentModel:create(params, { returning = "*" })
end

-- Get attachment by UUID
function ChatFileAttachmentQueries.show(uuid)
    return ChatFileAttachmentModel:find({ uuid = uuid })
end

-- Get attachments for a message
function ChatFileAttachmentQueries.getByMessage(message_uuid)
    local sql = [[
        SELECT * FROM chat_file_attachments
        WHERE message_uuid = ? AND is_deleted = false
        ORDER BY created_at ASC
    ]]
    return db.query(sql, message_uuid)
end

-- Get attachments for a channel
function ChatFileAttachmentQueries.getByChannel(channel_uuid, params)
    local limit = params.limit or 50
    local offset = params.offset or 0

    local sql = [[
        SELECT fa.*, u.first_name, u.last_name, u.username
        FROM chat_file_attachments fa
        INNER JOIN users u ON u.uuid = fa.user_uuid
        WHERE fa.channel_uuid = ? AND fa.is_deleted = false
        ORDER BY fa.created_at DESC
        LIMIT ? OFFSET ?
    ]]

    return db.query(sql, channel_uuid, limit, offset)
end

-- Get attachments by file type
function ChatFileAttachmentQueries.getByType(channel_uuid, file_type_pattern, params)
    local limit = params.limit or 50
    local offset = params.offset or 0

    local sql = [[
        SELECT fa.*, u.first_name, u.last_name
        FROM chat_file_attachments fa
        INNER JOIN users u ON u.uuid = fa.user_uuid
        WHERE fa.channel_uuid = ? AND fa.file_type LIKE ? AND fa.is_deleted = false
        ORDER BY fa.created_at DESC
        LIMIT ? OFFSET ?
    ]]

    return db.query(sql, channel_uuid, file_type_pattern, limit, offset)
end

-- Link attachment to message
function ChatFileAttachmentQueries.linkToMessage(attachment_uuid, message_uuid)
    local attachment = ChatFileAttachmentModel:find({ uuid = attachment_uuid })
    if not attachment then return nil end
    return attachment:update({ message_uuid = message_uuid }, { returning = "*" })
end

-- Soft delete attachment
function ChatFileAttachmentQueries.softDelete(uuid)
    local attachment = ChatFileAttachmentModel:find({ uuid = uuid })
    if not attachment then return nil end
    return attachment:update({ is_deleted = true }, { returning = "*" })
end

-- Get user's uploads
function ChatFileAttachmentQueries.getByUser(user_uuid, params)
    local limit = params.limit or 50
    local offset = params.offset or 0

    local sql = [[
        SELECT fa.*, c.name as channel_name
        FROM chat_file_attachments fa
        INNER JOIN chat_channels c ON c.uuid = fa.channel_uuid
        WHERE fa.user_uuid = ? AND fa.is_deleted = false
        ORDER BY fa.created_at DESC
        LIMIT ? OFFSET ?
    ]]

    return db.query(sql, user_uuid, limit, offset)
end

-- Get storage usage for a channel
function ChatFileAttachmentQueries.getChannelStorageUsage(channel_uuid)
    local sql = [[
        SELECT
            COUNT(*) as file_count,
            COALESCE(SUM(file_size), 0) as total_bytes
        FROM chat_file_attachments
        WHERE channel_uuid = ? AND is_deleted = false
    ]]

    local result = db.query(sql, channel_uuid)
    if result and result[1] then
        return {
            file_count = tonumber(result[1].file_count),
            total_bytes = tonumber(result[1].total_bytes)
        }
    end
    return { file_count = 0, total_bytes = 0 }
end

return ChatFileAttachmentQueries
