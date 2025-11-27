local ChatChannelMemberModel = require "models.ChatChannelMemberModel"
local Global = require "helper.global"
local db = require("lapis.db")

local ChatChannelMemberQueries = {}

-- Add member to channel
function ChatChannelMemberQueries.addMember(channel_uuid, user_uuid, role)
    role = role or "member"

    -- Check if member already exists (including left members)
    local existing = ChatChannelMemberModel:find({
        channel_uuid = channel_uuid,
        user_uuid = user_uuid
    })

    if existing then
        -- Rejoin if previously left
        if existing.left_at then
            return existing:update({
                left_at = db.NULL,
                role = role,
                joined_at = db.raw("NOW()")
            }, { returning = "*" })
        end
        -- Already a member
        return existing
    end

    -- Create new membership with explicit defaults
    return ChatChannelMemberModel:create({
        uuid = Global.generateUUID(),
        channel_uuid = channel_uuid,
        user_uuid = user_uuid,
        role = role,
        is_muted = false,
        notification_preference = "all",
        joined_at = db.raw("NOW()")
    }, { returning = "*" })
end

-- Remove member from channel (soft delete)
function ChatChannelMemberQueries.removeMember(channel_uuid, user_uuid)
    local member = ChatChannelMemberModel:find({
        channel_uuid = channel_uuid,
        user_uuid = user_uuid
    })

    if not member or member.left_at then
        return nil, "Member not found"
    end

    return member:update({
        left_at = db.raw("NOW()")
    }, { returning = "*" })
end

-- Update member role
function ChatChannelMemberQueries.updateRole(channel_uuid, user_uuid, new_role)
    local member = ChatChannelMemberModel:find({
        channel_uuid = channel_uuid,
        user_uuid = user_uuid
    })

    if not member or member.left_at then
        return nil, "Member not found"
    end

    return member:update({
        role = new_role
    }, { returning = "*" })
end

-- Update member settings (mute, notifications)
function ChatChannelMemberQueries.updateSettings(channel_uuid, user_uuid, settings)
    local member = ChatChannelMemberModel:find({
        channel_uuid = channel_uuid,
        user_uuid = user_uuid
    })

    if not member or member.left_at then
        return nil, "Member not found"
    end

    local update_params = {}
    if settings.is_muted ~= nil then
        update_params.is_muted = settings.is_muted
    end
    if settings.notification_preference then
        update_params.notification_preference = settings.notification_preference
    end

    if next(update_params) == nil then
        return member
    end

    return member:update(update_params, { returning = "*" })
end

-- Mark channel as read
function ChatChannelMemberQueries.markAsRead(channel_uuid, user_uuid)
    local member = ChatChannelMemberModel:find({
        channel_uuid = channel_uuid,
        user_uuid = user_uuid
    })

    if not member or member.left_at then
        return nil, "Member not found"
    end

    return member:update({
        last_read_at = db.raw("NOW()")
    }, { returning = "*" })
end

-- Get member details
function ChatChannelMemberQueries.getMember(channel_uuid, user_uuid)
    local sql = [[
        SELECT cm.*, u.email, u.first_name, u.last_name, u.username
        FROM chat_channel_members cm
        INNER JOIN users u ON u.uuid = cm.user_uuid
        WHERE cm.channel_uuid = ? AND cm.user_uuid = ? AND cm.left_at IS NULL
    ]]

    local result = db.query(sql, channel_uuid, user_uuid)
    if result and #result > 0 then
        return result[1]
    end
    return nil
end

-- Get all members with user details
function ChatChannelMemberQueries.getAllMembers(channel_uuid)
    local sql = [[
        SELECT cm.*, u.email, u.first_name, u.last_name, u.username
        FROM chat_channel_members cm
        INNER JOIN users u ON u.uuid = cm.user_uuid
        WHERE cm.channel_uuid = ? AND cm.left_at IS NULL
        ORDER BY cm.role ASC, cm.joined_at ASC
    ]]

    return db.query(sql, channel_uuid)
end

-- Get admins of a channel
function ChatChannelMemberQueries.getAdmins(channel_uuid)
    local sql = [[
        SELECT cm.*, u.email, u.first_name, u.last_name, u.username
        FROM chat_channel_members cm
        INNER JOIN users u ON u.uuid = cm.user_uuid
        WHERE cm.channel_uuid = ? AND cm.left_at IS NULL AND cm.role IN ('admin', 'moderator')
        ORDER BY cm.role ASC, cm.joined_at ASC
    ]]

    return db.query(sql, channel_uuid)
end

-- Count active members in a channel
function ChatChannelMemberQueries.countMembers(channel_uuid)
    local sql = [[
        SELECT COUNT(*) as count
        FROM chat_channel_members
        WHERE channel_uuid = ? AND left_at IS NULL
    ]]

    local result = db.query(sql, channel_uuid)
    if result and result[1] then
        return tonumber(result[1].count)
    end
    return 0
end

-- Bulk add members
function ChatChannelMemberQueries.addMembers(channel_uuid, user_uuids, role, added_by)
    role = role or "member"
    local added = {}
    local failed = {}

    for _, user_uuid in ipairs(user_uuids) do
        local member, err = ChatChannelMemberQueries.addMember(channel_uuid, user_uuid, role)
        if member then
            table.insert(added, member)
        else
            table.insert(failed, { user_uuid = user_uuid, error = err })
        end
    end

    return {
        added = added,
        failed = failed
    }
end

-- Get channels where user is admin
function ChatChannelMemberQueries.getAdminChannels(user_uuid)
    local sql = [[
        SELECT c.*
        FROM chat_channels c
        INNER JOIN chat_channel_members cm ON cm.channel_uuid = c.uuid
        WHERE cm.user_uuid = ? AND cm.left_at IS NULL AND cm.role IN ('admin', 'moderator')
        AND c.is_archived = false
        ORDER BY c.name ASC
    ]]

    return db.query(sql, user_uuid)
end

-- Transfer ownership (make another user admin and demote self)
function ChatChannelMemberQueries.transferOwnership(channel_uuid, current_admin_uuid, new_admin_uuid)
    -- First, make the new user an admin
    local new_admin, err = ChatChannelMemberQueries.updateRole(channel_uuid, new_admin_uuid, "admin")
    if not new_admin then
        return nil, "Failed to promote new admin: " .. (err or "unknown error")
    end

    -- Demote current admin to member (optional, could keep as admin)
    local current, err2 = ChatChannelMemberQueries.updateRole(channel_uuid, current_admin_uuid, "member")
    if not current then
        return nil, "Failed to demote current admin: " .. (err2 or "unknown error")
    end

    return {
        new_admin = new_admin,
        previous_admin = current
    }
end

return ChatChannelMemberQueries
