local ChatChannelInviteModel = require "models.ChatChannelInviteModel"
local Global = require "helper.global"
local db = require("lapis.db")

local ChatChannelInviteQueries = {}

-- Create an invitation
function ChatChannelInviteQueries.create(channel_uuid, invited_user_uuid, invited_by_uuid, message, expires_in_hours)
    local expires_at = nil
    if expires_in_hours then
        expires_at = db.raw(string.format("NOW() + INTERVAL '%d hours'", expires_in_hours))
    end

    return ChatChannelInviteModel:create({
        uuid = Global.generateUUID(),
        channel_uuid = channel_uuid,
        invited_user_uuid = invited_user_uuid,
        invited_by_uuid = invited_by_uuid,
        message = message,
        expires_at = expires_at
    }, { returning = "*" })
end

-- Get pending invitations for a user
function ChatChannelInviteQueries.getPendingForUser(user_uuid)
    local sql = [[
        SELECT i.*, c.name as channel_name, c.description as channel_description, c.type as channel_type,
               u.first_name as inviter_first_name, u.last_name as inviter_last_name
        FROM chat_channel_invites i
        INNER JOIN chat_channels c ON c.uuid = i.channel_uuid
        INNER JOIN users u ON u.uuid = i.invited_by_uuid
        WHERE i.invited_user_uuid = ?
          AND i.status = 'pending'
          AND (i.expires_at IS NULL OR i.expires_at > NOW())
        ORDER BY i.created_at DESC
    ]]

    return db.query(sql, user_uuid)
end

-- Accept invitation
function ChatChannelInviteQueries.accept(invite_uuid)
    local invite = ChatChannelInviteModel:find({ uuid = invite_uuid })
    if not invite then return nil, "Invitation not found" end

    if invite.status ~= "pending" then
        return nil, "Invitation is no longer pending"
    end

    if invite.expires_at then
        -- Check if expired
        local check_sql = "SELECT expires_at < NOW() as expired FROM chat_channel_invites WHERE uuid = ?"
        local result = db.query(check_sql, invite_uuid)
        if result and result[1] and result[1].expired then
            invite:update({ status = "expired" })
            return nil, "Invitation has expired"
        end
    end

    return invite:update({
        status = "accepted",
        responded_at = db.raw("NOW()")
    }, { returning = "*" })
end

-- Decline invitation
function ChatChannelInviteQueries.decline(invite_uuid)
    local invite = ChatChannelInviteModel:find({ uuid = invite_uuid })
    if not invite then return nil, "Invitation not found" end

    if invite.status ~= "pending" then
        return nil, "Invitation is no longer pending"
    end

    return invite:update({
        status = "declined",
        responded_at = db.raw("NOW()")
    }, { returning = "*" })
end

-- Get invitations sent by a user
function ChatChannelInviteQueries.getSentByUser(user_uuid)
    local sql = [[
        SELECT i.*, c.name as channel_name,
               u.first_name as invitee_first_name, u.last_name as invitee_last_name
        FROM chat_channel_invites i
        INNER JOIN chat_channels c ON c.uuid = i.channel_uuid
        INNER JOIN users u ON u.uuid = i.invited_user_uuid
        WHERE i.invited_by_uuid = ?
        ORDER BY i.created_at DESC
    ]]

    return db.query(sql, user_uuid)
end

-- Get invitations for a channel
function ChatChannelInviteQueries.getByChannel(channel_uuid)
    local sql = [[
        SELECT i.*,
               inv.first_name as invitee_first_name, inv.last_name as invitee_last_name,
               by.first_name as inviter_first_name, by.last_name as inviter_last_name
        FROM chat_channel_invites i
        INNER JOIN users inv ON inv.uuid = i.invited_user_uuid
        INNER JOIN users by ON by.uuid = i.invited_by_uuid
        WHERE i.channel_uuid = ?
        ORDER BY i.created_at DESC
    ]]

    return db.query(sql, channel_uuid)
end

-- Cancel invitation
function ChatChannelInviteQueries.cancel(invite_uuid, cancelled_by_uuid)
    local invite = ChatChannelInviteModel:find({ uuid = invite_uuid })
    if not invite then return nil, "Invitation not found" end

    -- Only the inviter can cancel
    if invite.invited_by_uuid ~= cancelled_by_uuid then
        return nil, "Only the inviter can cancel the invitation"
    end

    if invite.status ~= "pending" then
        return nil, "Invitation is no longer pending"
    end

    return invite:delete()
end

-- Expire old invitations (to be called periodically)
function ChatChannelInviteQueries.expireOldInvitations()
    local sql = [[
        UPDATE chat_channel_invites
        SET status = 'expired', updated_at = NOW()
        WHERE status = 'pending'
          AND expires_at IS NOT NULL
          AND expires_at < NOW()
        RETURNING *
    ]]

    return db.query(sql)
end

-- Check if user has pending invitation to channel
function ChatChannelInviteQueries.hasPendingInvitation(channel_uuid, user_uuid)
    local sql = [[
        SELECT COUNT(*) as count
        FROM chat_channel_invites
        WHERE channel_uuid = ?
          AND invited_user_uuid = ?
          AND status = 'pending'
          AND (expires_at IS NULL OR expires_at > NOW())
    ]]

    local result = db.query(sql, channel_uuid, user_uuid)
    return result and result[1] and tonumber(result[1].count) > 0
end

return ChatChannelInviteQueries
