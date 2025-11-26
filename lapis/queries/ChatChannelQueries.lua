local ChatChannelModel = require "models.ChatChannelModel"
local ChatChannelMemberModel = require "models.ChatChannelMemberModel"
local Global = require "helper.global"
local db = require("lapis.db")

local ChatChannelQueries = {}

-- Create a new channel
function ChatChannelQueries.create(params)
    if not params.uuid then
        params.uuid = Global.generateUUID()
    end
    if not params.type then
        params.type = "public"
    end
    return ChatChannelModel:create(params, { returning = "*" })
end

-- Get all channels for a business
function ChatChannelQueries.getByBusiness(uuid_business_id, params)
    local page = params.page or 1
    local perPage = params.perPage or 20
    local orderField = params.orderBy or "created_at"
    local orderDir = params.orderDir or "desc"

    local paginated = ChatChannelModel:paginated(
        "WHERE uuid_business_id = ? AND is_archived = false ORDER BY " .. orderField .. " " .. orderDir,
        { per_page = perPage },
        uuid_business_id
    )

    return {
        data = paginated:get_page(page),
        total = paginated:total_items()
    }
end

-- Get all channels for a user (channels they are a member of)
function ChatChannelQueries.getByUser(user_uuid, params)
    local page = params.page or 1
    local perPage = params.perPage or 20
    local offset = (page - 1) * perPage

    local sql = [[
        SELECT c.*,
               cm.role as member_role,
               cm.is_muted,
               cm.notification_preference,
               cm.last_read_at,
               (SELECT COUNT(*) FROM chat_messages m
                WHERE m.channel_uuid = c.uuid
                AND m.is_deleted = false
                AND m.created_at > COALESCE(cm.last_read_at, '1970-01-01')) as unread_count
        FROM chat_channels c
        INNER JOIN chat_channel_members cm ON cm.channel_uuid = c.uuid
        WHERE cm.user_uuid = ? AND cm.left_at IS NULL AND c.is_archived = false
        ORDER BY c.last_message_at DESC NULLS LAST, c.created_at DESC
        LIMIT ? OFFSET ?
    ]]

    local channels = db.query(sql, user_uuid, perPage, offset)

    local count_sql = [[
        SELECT COUNT(*) as total
        FROM chat_channels c
        INNER JOIN chat_channel_members cm ON cm.channel_uuid = c.uuid
        WHERE cm.user_uuid = ? AND cm.left_at IS NULL AND c.is_archived = false
    ]]
    local count_result = db.query(count_sql, user_uuid)
    local total = count_result and count_result[1] and count_result[1].total or 0

    return {
        data = channels,
        total = tonumber(total)
    }
end

-- Get single channel by UUID
function ChatChannelQueries.show(uuid)
    return ChatChannelModel:find({ uuid = uuid })
end

-- Get channel with member count
function ChatChannelQueries.showWithDetails(uuid, user_uuid)
    local sql = [[
        SELECT c.*,
               (SELECT COUNT(*) FROM chat_channel_members WHERE channel_uuid = c.uuid AND left_at IS NULL) as member_count,
               cm.role as current_user_role,
               cm.is_muted,
               cm.notification_preference,
               cm.last_read_at
        FROM chat_channels c
        LEFT JOIN chat_channel_members cm ON cm.channel_uuid = c.uuid AND cm.user_uuid = ?
        WHERE c.uuid = ?
    ]]

    local result = db.query(sql, user_uuid, uuid)
    if result and #result > 0 then
        return result[1]
    end
    return nil
end

-- Update channel
function ChatChannelQueries.update(uuid, params)
    local record = ChatChannelModel:find({ uuid = uuid })
    if not record then return nil end
    return record:update(params, { returning = "*" })
end

-- Delete (archive) channel
function ChatChannelQueries.archive(uuid)
    local record = ChatChannelModel:find({ uuid = uuid })
    if not record then return nil end
    return record:update({ is_archived = true }, { returning = "*" })
end

-- Hard delete channel
function ChatChannelQueries.destroy(uuid)
    local record = ChatChannelModel:find({ uuid = uuid })
    if not record then return nil end
    return record:delete()
end

-- Get channel members
function ChatChannelQueries.getMembers(channel_uuid, params)
    local page = params.page or 1
    local perPage = params.perPage or 50

    local sql = [[
        SELECT cm.*, u.email, u.first_name, u.last_name, u.username
        FROM chat_channel_members cm
        INNER JOIN users u ON u.uuid = cm.user_uuid
        WHERE cm.channel_uuid = ? AND cm.left_at IS NULL
        ORDER BY cm.role ASC, cm.joined_at ASC
        LIMIT ? OFFSET ?
    ]]

    local offset = (page - 1) * perPage
    local members = db.query(sql, channel_uuid, perPage, offset)

    local count_sql = [[
        SELECT COUNT(*) as total
        FROM chat_channel_members
        WHERE channel_uuid = ? AND left_at IS NULL
    ]]
    local count_result = db.query(count_sql, channel_uuid)
    local total = count_result and count_result[1] and count_result[1].total or 0

    return {
        data = members,
        total = tonumber(total)
    }
end

-- Check if user is member of channel
function ChatChannelQueries.isMember(channel_uuid, user_uuid)
    local sql = [[
        SELECT COUNT(*) as count
        FROM chat_channel_members
        WHERE channel_uuid = ? AND user_uuid = ? AND left_at IS NULL
    ]]
    local result = db.query(sql, channel_uuid, user_uuid)
    return result and result[1] and tonumber(result[1].count) > 0
end

-- Check if user is admin of channel
function ChatChannelQueries.isAdmin(channel_uuid, user_uuid)
    local sql = [[
        SELECT COUNT(*) as count
        FROM chat_channel_members
        WHERE channel_uuid = ? AND user_uuid = ? AND left_at IS NULL AND role IN ('admin', 'moderator')
    ]]
    local result = db.query(sql, channel_uuid, user_uuid)
    return result and result[1] and tonumber(result[1].count) > 0
end

-- Update last message timestamp
function ChatChannelQueries.updateLastMessageAt(channel_uuid)
    local sql = "UPDATE chat_channels SET last_message_at = NOW(), updated_at = NOW() WHERE uuid = ?"
    return db.query(sql, channel_uuid)
end

-- Create default channels for a business
function ChatChannelQueries.createDefaults(uuid_business_id, created_by)
    local defaults = {
        { name = "general", description = "General discussion", type = "public" },
        { name = "random", description = "Random conversations", type = "public" }
    }

    local created = {}

    for _, default in ipairs(defaults) do
        local channel = ChatChannelQueries.create({
            uuid = Global.generateUUID(),
            name = default.name,
            description = default.description,
            type = default.type,
            created_by = created_by,
            uuid_business_id = uuid_business_id,
            is_default = true
        })

        if channel then
            table.insert(created, channel)
        end
    end

    return created
end

-- Search channels
function ChatChannelQueries.search(uuid_business_id, search_term, params)
    local page = params.page or 1
    local perPage = params.perPage or 20
    local offset = (page - 1) * perPage

    local sql = [[
        SELECT c.*
        FROM chat_channels c
        WHERE c.uuid_business_id = ?
          AND c.is_archived = false
          AND (c.name ILIKE ? OR c.description ILIKE ?)
        ORDER BY c.name ASC
        LIMIT ? OFFSET ?
    ]]

    local search_pattern = "%" .. search_term .. "%"
    local channels = db.query(sql, uuid_business_id, search_pattern, search_pattern, perPage, offset)

    return {
        data = channels,
        total = #channels
    }
end

-- Get direct message channel between two users
function ChatChannelQueries.getDirectChannel(user1_uuid, user2_uuid)
    local sql = [[
        SELECT c.*
        FROM chat_channels c
        INNER JOIN chat_channel_members cm1 ON cm1.channel_uuid = c.uuid AND cm1.user_uuid = ? AND cm1.left_at IS NULL
        INNER JOIN chat_channel_members cm2 ON cm2.channel_uuid = c.uuid AND cm2.user_uuid = ? AND cm2.left_at IS NULL
        WHERE c.type = 'direct'
        AND (SELECT COUNT(*) FROM chat_channel_members WHERE channel_uuid = c.uuid AND left_at IS NULL) = 2
        LIMIT 1
    ]]

    local result = db.query(sql, user1_uuid, user2_uuid)
    if result and #result > 0 then
        return result[1]
    end
    return nil
end

return ChatChannelQueries
