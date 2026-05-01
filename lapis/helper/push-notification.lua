--[[
    Unified Push Notification Helper

    Routes all push notifications through FCM (Firebase Cloud Messaging).

    The Flutter mobile app registers FCM tokens via FirebaseMessaging.getToken()
    for ALL platforms including iOS. FCM tokens are NOT raw APNs device tokens —
    they can only be used with the FCM HTTP v1 API, which handles APNs delivery
    internally for iOS devices.

    The APNs helper (helper/apns-push.lua) is kept for future use if we ever
    switch to registering raw APNs device tokens via getAPNSToken() on the
    client side.
]]

local DeviceTokenQueries = require("queries.DeviceTokenQueries")

local PushNotification = {}

-- Lazy load FCM module
local function get_fcm()
    local ok, fcm = pcall(require, "helper.fcm-push")
    if ok then return fcm end
    ngx.log(ngx.ERR, "[Push] FCM module not available")
    return nil
end

-- Send notification to a single device (always via FCM)
function PushNotification.sendToDevice(device_token, device_type, notification, data)
    local fcm = get_fcm()
    if fcm then
        return fcm.sendToDevice(device_token, notification, data)
    end
    return false, "FCM not configured"
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

    local fcm_tokens = {}
    for _, token in ipairs(tokens) do
        table.insert(fcm_tokens, token.fcm_token)
    end

    local total_success = 0
    local total_failure = 0

    if #fcm_tokens > 0 then
        local fcm = get_fcm()
        if fcm then
            local ok, result = fcm.sendToDevices(fcm_tokens, notification, data)
            if result then
                total_success = total_success + (result.success or 0)
                total_failure = total_failure + (result.failure or 0)
            end
            ngx.log(ngx.NOTICE, "[Push] FCM: sent to ", #fcm_tokens, " devices (success=", total_success, ", failure=", total_failure, ")")
        else
            total_failure = total_failure + #fcm_tokens
            ngx.log(ngx.ERR, "[Push] FCM module not available, cannot send to ", #fcm_tokens, " devices")
        end
    end

    return total_success > 0, {
        success = total_success,
        failure = total_failure,
        total_devices = #fcm_tokens
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
