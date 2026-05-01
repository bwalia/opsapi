--[[
    Test Notification Route

    For testing push notifications. Remove in production.
]]

local cJson = require("cjson")
local PushNotification = require "helper.push-notification"
local AuthMiddleware = require("middleware.auth")
local db = require("lapis.db")

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

        ngx.log(ngx.NOTICE, "[TestNotification] Raw body: ", body or "nil")

        if not body or body == "" then
            return {}
        end

        local ok, result = pcall(cJson.decode, body)
        if ok and type(result) == "table" then
            return result
        end

        ngx.log(ngx.ERR, "[TestNotification] Failed to parse JSON: ", body)
        return {}
    end

    -- POST /api/v2/test-notification - Send test notification
    -- Body: { "title": "...", "body": "...", "user_uuid": "..." (optional) }
    -- TODO: Re-enable auth after testing: AuthMiddleware.requireAuth(function(self)
    app:post("/api/v2/test-notification", function(self)
        local data = parse_json_body()

        -- Debug logging
        ngx.log(ngx.NOTICE, "[TestNotification] Parsed data: ", cJson.encode(data))

        local title = data.title or "Test Notification"
        local body = data.body or "This is a test notification"

        ngx.log(ngx.NOTICE, "[TestNotification] Title: ", title, ", Body: ", body)

        local recipient_uuids = {}

        if data.user_uuid then
            -- Send to specific user
            table.insert(recipient_uuids, data.user_uuid)
        else
            -- Send to all users with registered tokens
            local tokens = db.query([[
                SELECT DISTINCT user_uuid FROM device_tokens WHERE is_active = true
            ]])
            for _, t in ipairs(tokens or {}) do
                table.insert(recipient_uuids, t.user_uuid)
            end
        end

        if #recipient_uuids == 0 then
            return {
                status = 400,
                json = { error = "No users with registered device tokens found" }
            }
        end

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
    end)

    -- GET /api/v2/test-notification/tokens - List all registered tokens (for debugging)
    app:get("/api/v2/test-notification/tokens", AuthMiddleware.requireAuth(function(self)
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
