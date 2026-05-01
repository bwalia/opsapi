--[[
    APNs Push Notification Helper

    Sends push notifications directly to Apple Push Notification service.
    Uses JWT (ES256) authentication with .p8 key file.

    Required environment variables:
    - APNS_KEY_ID: Key ID from Apple Developer Portal
    - APNS_TEAM_ID: Your Apple Team ID
    - APNS_KEY_PATH: Path to the .p8 private key file
    - APNS_BUNDLE_ID: Your app's bundle identifier
    - APNS_ENVIRONMENT: 'production' or 'development'
]]

local cjson = require("cjson")
local Global = require("helper.global")
local DeviceTokenQueries = require("queries.DeviceTokenQueries")

local APNsPush = {}

-- Cache for JWT token
local cached_jwt = nil
local jwt_expiry = 0

-- APNs endpoints
local APNS_PRODUCTION = "api.push.apple.com"
local APNS_SANDBOX = "api.sandbox.push.apple.com"

-- Load APNs configuration
local function get_apns_config()
    local key_id = Global.getEnvVar("APNS_KEY_ID")
    local team_id = Global.getEnvVar("APNS_TEAM_ID")
    local key_path = Global.getEnvVar("APNS_KEY_PATH")
    local bundle_id = Global.getEnvVar("APNS_BUNDLE_ID")
    local environment = Global.getEnvVar("APNS_ENVIRONMENT") or "development"

    if not key_id or not team_id or not key_path or not bundle_id then
        ngx.log(ngx.ERR, "[APNs] Missing required configuration")
        return nil
    end

    return {
        key_id = key_id,
        team_id = team_id,
        key_path = key_path,
        bundle_id = bundle_id,
        environment = environment
    }
end

-- Load private key from .p8 file
local function load_private_key(key_path)
    local file = io.open(key_path, "r")
    if not file then
        ngx.log(ngx.ERR, "[APNs] Cannot open key file: ", key_path)
        return nil
    end
    local content = file:read("*all")
    file:close()
    return content
end

-- Base64 URL encode (no padding)
local function base64url_encode(input)
    local b64 = ngx.encode_base64(input)
    -- Convert to URL-safe base64
    b64 = b64:gsub("+", "-"):gsub("/", "_"):gsub("=", "")
    return b64
end

-- Convert DER signature to raw R||S format (64 bytes for P-256)
local function der_to_raw(der)
    local pos = 1

    -- Skip sequence header (0x30 <len>)
    if der:byte(pos) ~= 0x30 then
        return nil, "Invalid DER: not a sequence"
    end
    pos = pos + 1
    local seq_len = der:byte(pos)
    pos = pos + 1
    if seq_len >= 0x80 then
        local len_bytes = seq_len - 0x80
        pos = pos + len_bytes
    end

    -- Read R integer
    if der:byte(pos) ~= 0x02 then
        return nil, "Invalid DER: R not an integer"
    end
    pos = pos + 1
    local r_len = der:byte(pos)
    pos = pos + 1
    local r = der:sub(pos, pos + r_len - 1)
    pos = pos + r_len

    -- Read S integer
    if der:byte(pos) ~= 0x02 then
        return nil, "Invalid DER: S not an integer"
    end
    pos = pos + 1
    local s_len = der:byte(pos)
    pos = pos + 1
    local s = der:sub(pos, pos + s_len - 1)

    -- Pad or trim R and S to 32 bytes each
    local function pad_or_trim(val, size)
        if #val > size then
            return val:sub(#val - size + 1)
        elseif #val < size then
            return string.rep("\0", size - #val) .. val
        end
        return val
    end

    r = pad_or_trim(r, 32)
    s = pad_or_trim(s, 32)

    return r .. s
end

-- Create JWT for APNs authentication (ES256)
local function create_apns_jwt(config)
    local now = ngx.time()

    -- Check cache (JWT is valid for up to 1 hour, we refresh at 50 minutes)
    if cached_jwt and now < jwt_expiry - 600 then
        return cached_jwt
    end

    local header = {
        alg = "ES256",
        kid = config.key_id
    }

    local payload = {
        iss = config.team_id,
        iat = now
    }

    local header_b64 = base64url_encode(cjson.encode(header))
    local payload_b64 = base64url_encode(cjson.encode(payload))
    local signing_input = header_b64 .. "." .. payload_b64

    -- Load private key
    local private_key = load_private_key(config.key_path)
    if not private_key then
        return nil, "Failed to load private key"
    end

    -- Sign with ES256 using resty.openssl
    local openssl_pkey = require("resty.openssl.pkey")
    local pkey, pkey_err = openssl_pkey.new(private_key)
    if not pkey then
        ngx.log(ngx.ERR, "[APNs] Failed to load private key: ", pkey_err)
        return nil, pkey_err
    end

    -- Sign the data (resty.openssl handles the hashing internally for ECDSA)
    local signature, sign_err = pkey:sign(signing_input, "sha256", nil, { ecdsa_use_raw = false })
    if not signature then
        ngx.log(ngx.ERR, "[APNs] Failed to sign JWT: ", sign_err)
        return nil, sign_err
    end

    -- Convert DER signature to raw format for JWT
    local raw_sig, conv_err = der_to_raw(signature)
    if not raw_sig then
        ngx.log(ngx.ERR, "[APNs] Failed to convert signature: ", conv_err)
        return nil, conv_err
    end

    local signature_b64 = base64url_encode(raw_sig)
    local jwt = signing_input .. "." .. signature_b64

    -- Cache the JWT
    cached_jwt = jwt
    jwt_expiry = now + 3600 -- 1 hour

    ngx.log(ngx.DEBUG, "[APNs] Created new JWT token")
    return jwt
end

-- Get APNs host based on environment
local function get_apns_host(environment)
    if environment == "production" then
        return APNS_PRODUCTION
    end
    return APNS_SANDBOX
end

-- Send push notification to a single device using curl (HTTP/2 required for APNs)
function APNsPush.sendToDevice(device_token, notification, data, config)
    config = config or get_apns_config()
    if not config then
        return false, "APNs not configured"
    end

    local jwt, jwt_err = create_apns_jwt(config)
    if not jwt then
        return false, jwt_err
    end

    local apns_host = get_apns_host(config.environment)
    local url = "https://" .. apns_host .. "/3/device/" .. device_token

    -- Build APNs payload
    local aps = {
        alert = {
            title = notification.title,
            body = notification.body
        },
        sound = "default",
        badge = 1
    }

    -- Add custom data
    local payload = {
        aps = aps
    }

    if data then
        for k, v in pairs(data) do
            payload[k] = v
        end
    end

    local payload_json = cjson.encode(payload)

    ngx.log(ngx.NOTICE, "[APNs] Sending payload: ", payload_json)

    -- Use curl with HTTP/2 support (APNs requires HTTP/2)
    local curl_cmd = string.format(
        'curl -s -w "\\n%%{http_code}" --http2 -X POST "%s" ' ..
        '-H "Authorization: bearer %s" ' ..
        '-H "apns-topic: %s" ' ..
        '-H "apns-push-type: alert" ' ..
        '-H "apns-priority: 10" ' ..
        '-H "Content-Type: application/json" ' ..
        '-d \'%s\' 2>&1',
        url,
        jwt,
        config.bundle_id,
        payload_json:gsub("'", "'\\''")  -- Escape single quotes for shell
    )

    local handle = io.popen(curl_cmd)
    local result = handle:read("*a")
    handle:close()

    -- Parse response (body + status code on last line)
    local lines = {}
    for line in result:gmatch("[^\r\n]+") do
        table.insert(lines, line)
    end

    local status_code = tonumber(lines[#lines]) or 0
    local response_body = table.concat(lines, "\n", 1, #lines - 1)

    -- Handle APNs responses
    if status_code == 200 then
        ngx.log(ngx.DEBUG, "[APNs] Notification sent successfully to: ", device_token)
        return true, { status = "sent" }
    end

    -- Parse error response
    local response_data = {}
    if response_body and response_body ~= "" then
        local ok, parsed = pcall(cjson.decode, response_body)
        if ok then
            response_data = parsed
        end
    end

    local reason = response_data.reason or "Unknown"
    ngx.log(ngx.ERR, "[APNs] Error: ", status_code, " - ", reason, " - Body: ", response_body)

    -- Handle invalid/expired tokens
    if status_code == 400 or status_code == 410 then
        if reason == "BadDeviceToken" or reason == "Unregistered" or reason == "ExpiredToken" then
            ngx.log(ngx.WARN, "[APNs] Invalid token, removing: ", device_token)
            DeviceTokenQueries.removeInvalidToken(device_token)
            return false, "Invalid token: " .. reason
        end
    end

    return false, "APNs error " .. status_code .. ": " .. reason
end

-- Send push notification to multiple devices
function APNsPush.sendToDevices(device_tokens, notification, data)
    if not device_tokens or #device_tokens == 0 then
        return true, { success = 0, failure = 0 }
    end

    local config = get_apns_config()
    if not config then
        return false, "APNs not configured"
    end

    local success_count = 0
    local failure_count = 0

    for _, token in ipairs(device_tokens) do
        local ok, _ = APNsPush.sendToDevice(token, notification, data, config)
        if ok then
            success_count = success_count + 1
        else
            failure_count = failure_count + 1
        end
    end

    return success_count > 0, { success = success_count, failure = failure_count }
end

-- Send push notification to a user (all their devices)
function APNsPush.sendToUser(user_uuid, notification, data)
    local tokens = DeviceTokenQueries.getByUser(user_uuid)

    if not tokens or #tokens == 0 then
        ngx.log(ngx.DEBUG, "[APNs] No active tokens for user: ", user_uuid)
        return true, { success = 0, failure = 0, message = "No active devices" }
    end

    local device_tokens = {}
    for _, token in ipairs(tokens) do
        table.insert(device_tokens, token.fcm_token)  -- Column name is still fcm_token
    end

    return APNsPush.sendToDevices(device_tokens, notification, data)
end

-- Send push notification to multiple users
function APNsPush.sendToUsers(user_uuids, notification, data)
    if not user_uuids or #user_uuids == 0 then
        return true, { success = 0, failure = 0 }
    end

    local tokens = DeviceTokenQueries.getActiveTokensForUsers(user_uuids)

    if not tokens or #tokens == 0 then
        ngx.log(ngx.DEBUG, "[APNs] No active tokens for users")
        return true, { success = 0, failure = 0, message = "No active devices" }
    end

    local device_tokens = {}
    for _, token in ipairs(tokens) do
        table.insert(device_tokens, token.fcm_token)  -- Column name is still fcm_token
    end

    return APNsPush.sendToDevices(device_tokens, notification, data)
end

-- Helper: Send notification to users
function APNsPush.sendNotification(recipient_uuids, title, body, extra_data)
    local notification = {
        title = title,
        body = body
    }

    local data = extra_data or {}
    -- Ensure all data values are strings (for consistency)
    for k, v in pairs(data) do
        data[k] = tostring(v)
    end

    return APNsPush.sendToUsers(recipient_uuids, notification, data)
end

return APNsPush
