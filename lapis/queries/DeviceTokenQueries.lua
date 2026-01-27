local Global = require "helper.global"
local DeviceTokens = require "models.DeviceTokenModel"
local db = require("lapis.db")

local DeviceTokenQueries = {}

-- Helper to convert cjson.null to nil
local function sanitize_null(value)
    if value == nil or value == ngx.null or (type(value) == "userdata") then
        return nil
    end
    return value
end

-- Register or update a device token
function DeviceTokenQueries.register(data, user_uuid)
    -- Sanitize optional fields that might be cjson.null
    local device_name = sanitize_null(data.device_name)
    local device_type = sanitize_null(data.device_type)

    -- Check if token already exists for this user
    local existing = db.query([[
        SELECT * FROM device_tokens
        WHERE user_uuid = ? AND fcm_token = ?
        LIMIT 1
    ]], user_uuid, data.fcm_token)

    if existing and #existing > 0 then
        -- Update existing token
        db.query([[
            UPDATE device_tokens
            SET is_active = true,
                device_type = COALESCE(?, device_type),
                device_name = COALESCE(?, device_name),
                updated_at = NOW()
            WHERE id = ?
        ]], device_type, device_name, existing[1].id)

        return DeviceTokenQueries.show(existing[1].uuid)
    end

    -- Deactivate old tokens for this device if fcm_token changed
    if device_name then
        db.query([[
            UPDATE device_tokens
            SET is_active = false, updated_at = NOW()
            WHERE user_uuid = ? AND device_name = ? AND fcm_token != ?
        ]], user_uuid, device_name, data.fcm_token)
    end

    -- Create new token
    local token_data = {
        uuid = Global.generateUUID(),
        user_uuid = user_uuid,
        fcm_token = data.fcm_token,
        device_type = device_type,
        device_name = device_name,
        is_active = true
    }

    local token = DeviceTokens:create(token_data, { returning = "*" })
    if token then
        token.internal_id = token.id
        token.id = token.uuid
    end
    return token
end

-- Get token by UUID
function DeviceTokenQueries.show(uuid)
    local token = DeviceTokens:find({ uuid = uuid })
    if token then
        token.internal_id = token.id
        token.id = token.uuid
    end
    return token
end

-- Get all active tokens for a user
function DeviceTokenQueries.getByUser(user_uuid)
    local tokens = db.query([[
        SELECT id as internal_id, uuid as id, user_uuid, fcm_token,
               device_type, device_name, is_active, created_at, updated_at
        FROM device_tokens
        WHERE user_uuid = ? AND is_active = true
        ORDER BY updated_at DESC
    ]], user_uuid)

    return tokens or {}
end

-- Get active FCM tokens for multiple users (for sending push notifications)
function DeviceTokenQueries.getActiveTokensForUsers(user_uuids)
    if not user_uuids or #user_uuids == 0 then
        return {}
    end

    local placeholders = {}
    for i = 1, #user_uuids do
        placeholders[i] = "?"
    end

    local sql = [[
        SELECT user_uuid, fcm_token, device_type
        FROM device_tokens
        WHERE user_uuid IN (]] .. table.concat(placeholders, ", ") .. [[)
          AND is_active = true
    ]]

    local tokens = db.query(sql, table.unpack(user_uuids))
    return tokens or {}
end

-- Deactivate a token (logout)
function DeviceTokenQueries.deactivate(fcm_token, user_uuid)
    local result = db.query([[
        UPDATE device_tokens
        SET is_active = false, updated_at = NOW()
        WHERE fcm_token = ? AND user_uuid = ?
        RETURNING *
    ]], fcm_token, user_uuid)

    return result and #result > 0
end

-- Deactivate all tokens for a user (logout from all devices)
function DeviceTokenQueries.deactivateAll(user_uuid)
    local result = db.query([[
        UPDATE device_tokens
        SET is_active = false, updated_at = NOW()
        WHERE user_uuid = ?
    ]], user_uuid)

    return true
end

-- Remove invalid token (called when FCM returns invalid token error)
function DeviceTokenQueries.removeInvalidToken(fcm_token)
    db.query([[
        DELETE FROM device_tokens WHERE fcm_token = ?
    ]], fcm_token)
end

-- Delete a specific token
function DeviceTokenQueries.destroy(uuid, user_uuid)
    local token = DeviceTokens:find({ uuid = uuid, user_uuid = user_uuid })
    if not token then
        return false
    end
    return token:delete()
end

return DeviceTokenQueries
