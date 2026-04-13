--[[
    FCM Push Notification Helper (HTTP v1 API)

    Sends push notifications to iOS and Android devices via Firebase Cloud Messaging.
    Uses Service Account authentication with OAuth2 access tokens.

    Required environment variables:
    - FCM_PROJECT_ID: Firebase project ID
    - FCM_CLIENT_EMAIL: Service account email
    - FCM_PRIVATE_KEY: Service account private key (PEM format)

    OR
    - FCM_SERVICE_ACCOUNT_JSON: Full path to service account JSON file
]]

local http = require("resty.http")
local cjson = require("cjson")
local Global = require("helper.global")
local DeviceTokenQueries = require("queries.DeviceTokenQueries")

local FCMPush = {}

-- Cache for access token
local cached_token = nil
local token_expiry = 0

-- Load service account credentials
local function get_service_account()
    -- Try loading from JSON file first
    local json_path = Global.getEnvVar("FCM_SERVICE_ACCOUNT_JSON")
    if json_path then
        local file = io.open(json_path, "r")
        if file then
            local content = file:read("*all")
            file:close()
            local ok, sa = pcall(cjson.decode, content)
            if ok and sa then
                return {
                    project_id = sa.project_id,
                    client_email = sa.client_email,
                    private_key = sa.private_key
                }
            end
        end
    end

    -- Fall back to individual environment variables
    local project_id = Global.getEnvVar("FCM_PROJECT_ID")
    local client_email = Global.getEnvVar("FCM_CLIENT_EMAIL")
    local private_key = Global.getEnvVar("FCM_PRIVATE_KEY")

    if project_id and client_email and private_key then
        -- Handle escaped newlines in private key
        private_key = private_key:gsub("\\n", "\n")
        return {
            project_id = project_id,
            client_email = client_email,
            private_key = private_key
        }
    end

    return nil
end

-- Base64 URL encode (no padding)
local function base64url_encode(input)
    local b64 = ngx.encode_base64(input)
    -- Convert to URL-safe base64
    b64 = b64:gsub("+", "-"):gsub("/", "_"):gsub("=", "")
    return b64
end

-- Create JWT for Google OAuth2
local function create_jwt(service_account)
    local now = ngx.time()
    local exp = now + 3600 -- 1 hour expiry

    local header = {
        alg = "RS256",
        typ = "JWT"
    }

    local payload = {
        iss = service_account.client_email,
        sub = service_account.client_email,
        aud = "https://oauth2.googleapis.com/token",
        iat = now,
        exp = exp,
        scope = "https://www.googleapis.com/auth/firebase.messaging"
    }

    local header_b64 = base64url_encode(cjson.encode(header))
    local payload_b64 = base64url_encode(cjson.encode(payload))
    local signing_input = header_b64 .. "." .. payload_b64

    -- Sign with RSA-SHA256
    local resty_rsa = require("resty.rsa")
    local priv, err = resty_rsa:new({
        private_key = service_account.private_key,
        algorithm = "SHA256"
    })

    if not priv then
        ngx.log(ngx.ERR, "[FCM] Failed to load private key: ", err)
        return nil, err
    end

    local signature, sign_err = priv:sign(signing_input)
    if not signature then
        ngx.log(ngx.ERR, "[FCM] Failed to sign JWT: ", sign_err)
        return nil, sign_err
    end

    local signature_b64 = base64url_encode(signature)
    return signing_input .. "." .. signature_b64
end

-- Get OAuth2 access token
local function get_access_token(service_account)
    -- Check cache
    if cached_token and ngx.time() < token_expiry - 60 then
        return cached_token
    end

    local jwt, err = create_jwt(service_account)
    if not jwt then
        return nil, err
    end

    local httpc = http.new()
    httpc:set_timeout(10000)

    local res, req_err = httpc:request_uri("https://oauth2.googleapis.com/token", {
        method = "POST",
        headers = {
            ["Content-Type"] = "application/x-www-form-urlencoded"
        },
        body = "grant_type=urn:ietf:params:oauth:grant-type:jwt-bearer&assertion=" .. jwt,
        ssl_verify = false  -- TODO: Enable SSL verification in production with proper CA bundle
    })

    if not res then
        ngx.log(ngx.ERR, "[FCM] Token request failed: ", req_err)
        return nil, req_err
    end

    if res.status ~= 200 then
        ngx.log(ngx.ERR, "[FCM] Token error: ", res.status, " - ", res.body)
        return nil, "Token error: " .. res.status
    end

    local ok, token_data = pcall(cjson.decode, res.body)
    if not ok then
        ngx.log(ngx.ERR, "[FCM] Failed to parse token response: ", res.body)
        return nil, "Failed to parse token response"
    end

    if not token_data.access_token then
        ngx.log(ngx.ERR, "[FCM] No access_token in response: ", res.body)
        return nil, "No access_token in response"
    end

    ngx.log(ngx.DEBUG, "[FCM] Got access token: ", string.sub(token_data.access_token, 1, 20), "...")
    cached_token = token_data.access_token
    token_expiry = ngx.time() + (token_data.expires_in or 3600)

    return cached_token
end

-- Send push notification to a single device (FCM v1 API)
function FCMPush.sendToDevice(fcm_token, notification, data)
    local service_account = get_service_account()
    if not service_account then
        ngx.log(ngx.ERR, "[FCM] Service account not configured")
        return false, "FCM service account not configured"
    end

    local access_token, token_err = get_access_token(service_account)
    if not access_token then
        return false, token_err
    end

    local fcm_url = "https://fcm.googleapis.com/v1/projects/" .. service_account.project_id .. "/messages:send"

    local httpc = http.new()
    httpc:set_timeout(10000)

    -- Build v1 API payload
    local message = {
        token = fcm_token,
        notification = notification,
        data = data,
        android = {
            priority = "high"
        },
        apns = {
            payload = {
                aps = {
                    sound = "default",
                    badge = 1
                }
            }
        }
    }

    local payload = { message = message }

    local res, err = httpc:request_uri(fcm_url, {
        method = "POST",
        headers = {
            ["Content-Type"] = "application/json",
            ["Authorization"] = "Bearer " .. access_token
        },
        body = cjson.encode(payload),
        ssl_verify = false  -- TODO: Enable SSL verification in production with proper CA bundle
    })

    if not res then
        ngx.log(ngx.ERR, "[FCM] Request failed: ", err)
        return false, err
    end

    if res.status == 404 or res.status == 400 then
        local response = cjson.decode(res.body)
        if response.error and response.error.details then
            for _, detail in ipairs(response.error.details) do
                if detail.errorCode == "UNREGISTERED" or detail.errorCode == "INVALID_ARGUMENT" then
                    ngx.log(ngx.WARN, "[FCM] Invalid token, removing: ", fcm_token)
                    DeviceTokenQueries.removeInvalidToken(fcm_token)
                    return false, "Invalid token"
                end
            end
        end
        ngx.log(ngx.ERR, "[FCM] API error: ", res.status, " - ", res.body)
        return false, "FCM API error: " .. res.status
    end

    if res.status ~= 200 then
        ngx.log(ngx.ERR, "[FCM] API error: ", res.status, " - ", res.body)
        return false, "FCM API error: " .. res.status
    end

    return true, cjson.decode(res.body)
end

-- Send push notification to multiple devices (sends individually for v1 API)
function FCMPush.sendToDevices(fcm_tokens, notification, data)
    if not fcm_tokens or #fcm_tokens == 0 then
        return true, { success = 0, failure = 0 }
    end

    local success_count = 0
    local failure_count = 0

    for _, token in ipairs(fcm_tokens) do
        local ok, _ = FCMPush.sendToDevice(token, notification, data)
        if ok then
            success_count = success_count + 1
        else
            failure_count = failure_count + 1
        end
    end

    return success_count > 0, { success = success_count, failure = failure_count }
end

-- Send push notification to a user (all their devices)
function FCMPush.sendToUser(user_uuid, notification, data)
    local tokens = DeviceTokenQueries.getByUser(user_uuid)

    if not tokens or #tokens == 0 then
        ngx.log(ngx.DEBUG, "[FCM] No active tokens for user: ", user_uuid)
        return true, { success = 0, failure = 0, message = "No active devices" }
    end

    local fcm_tokens = {}
    for _, token in ipairs(tokens) do
        table.insert(fcm_tokens, token.fcm_token)
    end

    return FCMPush.sendToDevices(fcm_tokens, notification, data)
end

-- Send push notification to multiple users
function FCMPush.sendToUsers(user_uuids, notification, data)
    if not user_uuids or #user_uuids == 0 then
        return true, { success = 0, failure = 0 }
    end

    local tokens = DeviceTokenQueries.getActiveTokensForUsers(user_uuids)

    if not tokens or #tokens == 0 then
        ngx.log(ngx.DEBUG, "[FCM] No active tokens for users")
        return true, { success = 0, failure = 0, message = "No active devices" }
    end

    local fcm_tokens = {}
    for _, token in ipairs(tokens) do
        table.insert(fcm_tokens, token.fcm_token)
    end

    return FCMPush.sendToDevices(fcm_tokens, notification, data)
end

-- Helper: Send notification to users
function FCMPush.sendNotification(recipient_uuids, title, body, extra_data)
    local notification = {
        title = title,
        body = body
    }

    local data = extra_data or {}
    -- Ensure all data values are strings (FCM requirement)
    for k, v in pairs(data) do
        data[k] = tostring(v)
    end

    return FCMPush.sendToUsers(recipient_uuids, notification, data)
end

return FCMPush
