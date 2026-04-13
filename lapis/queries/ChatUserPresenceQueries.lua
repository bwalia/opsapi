local ChatUserPresenceModel = require "models.ChatUserPresenceModel"
local db = require("lapis.db")

local ChatUserPresenceQueries = {}

-- Update or create user presence
function ChatUserPresenceQueries.updatePresence(user_uuid, status, options)
    options = options or {}

    local existing = ChatUserPresenceModel:find({ user_uuid = user_uuid })

    local params = {
        status = status,
        last_seen_at = db.raw("NOW()"),
        last_active_at = db.raw("NOW()")
    }

    if options.status_text then
        params.status_text = options.status_text
    end
    if options.status_emoji then
        params.status_emoji = options.status_emoji
    end
    if options.current_channel_uuid then
        params.current_channel_uuid = options.current_channel_uuid
    end

    if existing then
        return existing:update(params, { returning = "*" })
    else
        params.user_uuid = user_uuid
        return ChatUserPresenceModel:create(params, { returning = "*" })
    end
end

-- Set user online
function ChatUserPresenceQueries.setOnline(user_uuid)
    return ChatUserPresenceQueries.updatePresence(user_uuid, "online")
end

-- Set user offline
function ChatUserPresenceQueries.setOffline(user_uuid)
    local existing = ChatUserPresenceModel:find({ user_uuid = user_uuid })
    if existing then
        return existing:update({
            status = "offline",
            last_seen_at = db.raw("NOW()"),
            current_channel_uuid = db.NULL
        }, { returning = "*" })
    end
    return nil
end

-- Set user away
function ChatUserPresenceQueries.setAway(user_uuid)
    return ChatUserPresenceQueries.updatePresence(user_uuid, "away")
end

-- Set user do not disturb
function ChatUserPresenceQueries.setDND(user_uuid)
    return ChatUserPresenceQueries.updatePresence(user_uuid, "dnd")
end

-- Get user presence
function ChatUserPresenceQueries.getPresence(user_uuid)
    return ChatUserPresenceModel:find({ user_uuid = user_uuid })
end

-- Get presence for multiple users
function ChatUserPresenceQueries.getMultiplePresence(user_uuids)
    if not user_uuids or #user_uuids == 0 then
        return {}
    end

    local placeholders = {}
    for i = 1, #user_uuids do
        table.insert(placeholders, "?")
    end

    local sql = string.format([[
        SELECT p.*, u.first_name, u.last_name, u.username
        FROM chat_user_presence p
        INNER JOIN users u ON u.uuid = p.user_uuid
        WHERE p.user_uuid IN (%s)
    ]], table.concat(placeholders, ", "))

    return db.query(sql, table.unpack(user_uuids))
end

-- Get online users in a channel
function ChatUserPresenceQueries.getOnlineInChannel(channel_uuid)
    local sql = [[
        SELECT p.*, u.first_name, u.last_name, u.username
        FROM chat_user_presence p
        INNER JOIN users u ON u.uuid = p.user_uuid
        INNER JOIN chat_channel_members cm ON cm.user_uuid = p.user_uuid
        WHERE cm.channel_uuid = ?
          AND cm.left_at IS NULL
          AND p.status IN ('online', 'away', 'dnd')
        ORDER BY p.status ASC, u.first_name ASC
    ]]

    return db.query(sql, channel_uuid)
end

-- Update current channel
function ChatUserPresenceQueries.setCurrentChannel(user_uuid, channel_uuid)
    local existing = ChatUserPresenceModel:find({ user_uuid = user_uuid })
    if existing then
        return existing:update({
            current_channel_uuid = channel_uuid,
            last_active_at = db.raw("NOW()")
        }, { returning = "*" })
    end
    return nil
end

-- Update custom status
function ChatUserPresenceQueries.setCustomStatus(user_uuid, status_text, status_emoji)
    local existing = ChatUserPresenceModel:find({ user_uuid = user_uuid })
    if existing then
        return existing:update({
            status_text = status_text,
            status_emoji = status_emoji
        }, { returning = "*" })
    end
    return nil
end

-- Clear custom status
function ChatUserPresenceQueries.clearCustomStatus(user_uuid)
    local existing = ChatUserPresenceModel:find({ user_uuid = user_uuid })
    if existing then
        return existing:update({
            status_text = db.NULL,
            status_emoji = db.NULL
        }, { returning = "*" })
    end
    return nil
end

-- Auto-set away for inactive users (to be called periodically)
function ChatUserPresenceQueries.setInactiveUsersAway(minutes)
    minutes = minutes or 15

    local sql = [[
        UPDATE chat_user_presence
        SET status = 'away', updated_at = NOW()
        WHERE status = 'online'
          AND last_active_at < NOW() - INTERVAL '%d minutes'
        RETURNING *
    ]]

    return db.query(string.format(sql, minutes))
end

-- Auto-set offline for very inactive users
function ChatUserPresenceQueries.setInactiveUsersOffline(minutes)
    minutes = minutes or 60

    local sql = [[
        UPDATE chat_user_presence
        SET status = 'offline', updated_at = NOW()
        WHERE status IN ('online', 'away')
          AND last_active_at < NOW() - INTERVAL '%d minutes'
        RETURNING *
    ]]

    return db.query(string.format(sql, minutes))
end

return ChatUserPresenceQueries
