--[[
    Test Notification Route

    For testing push notifications. Platform admins only: this used to be on
    the public allow-list with auth commented out, letting anyone on the
    internet push arbitrary text to every user of every tenant. It now needs a
    platform-admin JWT and an explicit target user — no broadcast.
]]

local cJson = require("cjson")
local PushNotification = require "helper.push-notification"
local AuthMiddleware = require("middleware.auth")
local db = require("lapis.db")

-- Platform admins only (exact "administrative" role).
local function platform_admin_only(handler)
    return AuthMiddleware.requireRole("administrative", handler)
end

return function(app)
    -- Helper function to parse JSON body
    local function parse_json_body()
        ngx.req.read_body()
        local body = ngx.req.get_body_data()

        -- If body is nil, try reading from file (for large bodies)
        if not body then
            local body_file = ngx.req.get_body_file()
            if body_file then
                local f = io.open(body_file, "r")
                if f then
                    body = f:read("*all")
                    f:close()
                end
            end
        end

        if not body or body == "" then
            return {}
        end

        local ok, result = pcall(cJson.decode, body)
        if ok and type(result) == "table" then
            return result
        end

        ngx.log(ngx.ERR, "[TestNotification] Failed to parse JSON body")
        return {}
    end

    -- POST /api/v2/test-notification - Send test notification
    -- Body: { "title": "...", "body": "...", "user_uuid": "..." (optional) }
    app:post("/api/v2/test-notification", platform_admin_only(function(self)
        local data = parse_json_body()

        local title = data.title or "Test Notification"
        local body = data.body or "This is a test notification"

        -- Always a single, explicit recipient: a test tool must never be able
        -- to broadcast to every user on the platform.
        if type(data.user_uuid) ~= "string" or data.user_uuid == "" then
            return { status = 400, json = { error = "user_uuid is required" } }
        end
        local recipient_uuids = { data.user_uuid }

        local success, result = PushNotification.sendNotification(recipient_uuids, title, body, {
            type = "test"
        })

        return {
            status = 200,
            json = {
                message = "Notification sent",
                recipients = #recipient_uuids,
                success = success,
                result = result
            }
        }
    end))

    -- GET /api/v2/test-notification/tokens - List all registered tokens (for debugging)
    app:get("/api/v2/test-notification/tokens", platform_admin_only(function(self)
        local tokens = db.query([[
            SELECT dt.uuid, dt.user_uuid, dt.device_type, dt.device_name, dt.is_active, dt.created_at,
                   u.first_name, u.last_name, u.email
            FROM device_tokens dt
            LEFT JOIN users u ON u.uuid = dt.user_uuid
            ORDER BY dt.created_at DESC
        ]])

        return {
            status = 200,
            json = {
                data = tokens or {},
                total = #(tokens or {})
            }
        }
    end))
end
