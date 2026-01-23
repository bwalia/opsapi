--[[
    Unified Push Notification Helper

    Routes push notifications to the correct service based on device type:
    - iOS: APNs (Apple Push Notification service)
    - Android: FCM (Firebase Cloud Messaging)
]]

local DeviceTokenQueries = require("queries.DeviceTokenQueries")

local PushNotification = {}

-- Lazy load platform-specific modules to avoid errors if not configured
local function get_apns()
    local ok, apns = pcall(require, "helper.apns-push")
    if ok then return apns end
    ngx.log(ngx.WARN, "[Push] APNs module not available")
    return nil
end

local function get_fcm()
    local ok, fcm = pcall(require, "helper.fcm-push")
    if ok then return fcm end
    ngx.log(ngx.WARN, "[Push] FCM module not available")
    return nil
end

-- Send notification to a single device
function PushNotification.sendToDevice(device_token, device_type, notification, data)
    if device_type == "ios" then
        local apns = get_apns()
        if apns then
            return apns.sendToDevice(device_token, notification, data)
        end
        return false, "APNs not configured"
    elseif device_type == "android" then
        local fcm = get_fcm()
        if fcm then
            return fcm.sendToDevice(device_token, notification, data)
        end
        return false, "FCM not configured"
    else
        ngx.log(ngx.WARN, "[Push] Unknown device type: ", device_type)
        return false, "Unknown device type"
    end
end

-- Send notification to multiple users
function PushNotification.sendToUsers(user_uuids, notification, data)
    if not user_uuids or #user_uuids == 0 then
        return true, { success = 0, failure = 0 }
    end

    local tokens = DeviceTokenQueries.getActiveTokensForUsers(user_uuids)

    if not tokens or #tokens == 0 then
        ngx.log(ngx.DEBUG, "[Push] No active tokens for users")
        return true, { success = 0, failure = 0, message = "No active devices" }
    end

    -- Separate tokens by platform
    local ios_tokens = {}
    local android_tokens = {}

    for _, token in ipairs(tokens) do
        if token.device_type == "ios" then
            table.insert(ios_tokens, token.fcm_token)
        elseif token.device_type == "android" then
            table.insert(android_tokens, token.fcm_token)
        else
            -- Default to FCM for unknown types (legacy behavior)
            table.insert(android_tokens, token.fcm_token)
        end
    end

    local total_success = 0
    local total_failure = 0

    -- Send to iOS devices via APNs
    if #ios_tokens > 0 then
        local apns = get_apns()
        if apns then
            local ok, result = apns.sendToDevices(ios_tokens, notification, data)
            if result then
                total_success = total_success + (result.success or 0)
                total_failure = total_failure + (result.failure or 0)
            end
            ngx.log(ngx.DEBUG, "[Push] APNs: sent to ", #ios_tokens, " iOS devices")
        else
            total_failure = total_failure + #ios_tokens
            ngx.log(ngx.WARN, "[Push] APNs not configured, skipping ", #ios_tokens, " iOS devices")
        end
    end

    -- Send to Android devices via FCM
    if #android_tokens > 0 then
        local fcm = get_fcm()
        if fcm then
            local ok, result = fcm.sendToDevices(android_tokens, notification, data)
            if result then
                total_success = total_success + (result.success or 0)
                total_failure = total_failure + (result.failure or 0)
            end
            ngx.log(ngx.DEBUG, "[Push] FCM: sent to ", #android_tokens, " Android devices")
        else
            total_failure = total_failure + #android_tokens
            ngx.log(ngx.WARN, "[Push] FCM not configured, skipping ", #android_tokens, " Android devices")
        end
    end

    return total_success > 0, {
        success = total_success,
        failure = total_failure,
        ios_count = #ios_tokens,
        android_count = #android_tokens
    }
end

-- Send notification to a single user (all their devices)
function PushNotification.sendToUser(user_uuid, notification, data)
    return PushNotification.sendToUsers({ user_uuid }, notification, data)
end

-- Helper: Send notification to users (convenience method)
function PushNotification.sendNotification(recipient_uuids, title, body, extra_data)
    local notification = {
        title = title,
        body = body
    }

    local data = extra_data or {}
    -- Ensure all data values are strings
    for k, v in pairs(data) do
        data[k] = tostring(v)
    end

    return PushNotification.sendToUsers(recipient_uuids, notification, data)
end

return PushNotification
