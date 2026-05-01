--[[
    Device Token Routes

    API endpoints for managing FCM device tokens for push notifications.
    All endpoints require authentication.
]]

local cJson = require("cjson")
local DeviceTokenQueries = require "queries.DeviceTokenQueries"
local AuthMiddleware = require("middleware.auth")

return function(app)
    -- Helper function to parse JSON body
    local function parse_json_body()
        local ok, result = pcall(function()
            ngx.req.read_body()
            local body = ngx.req.get_body_data()
            if not body or body == "" then
                return {}
            end
            return cJson.decode(body)
        end)

        if ok and type(result) == "table" then
            return result
        end
        return {}
    end

    -- POST /api/v2/device-tokens - Register a device token
    app:post("/api/v2/device-tokens", AuthMiddleware.requireAuth(function(self)
        local user = self.current_user
        local data = parse_json_body()

        -- Validate required fields
        if not data.fcm_token or data.fcm_token == "" then
            return {
                status = 400,
                json = { error = "fcm_token is required" }
            }
        end

        -- Validate device_type if provided
        if data.device_type then
            local valid_types = { ios = true, android = true }
            if not valid_types[data.device_type:lower()] then
                return {
                    status = 400,
                    json = { error = "device_type must be 'ios' or 'android'" }
                }
            end
            data.device_type = data.device_type:lower()
        end

        local token = DeviceTokenQueries.register(data, user.uuid)

        if not token then
            return {
                status = 500,
                json = { error = "Failed to register device token" }
            }
        end

        return {
            status = 201,
            json = {
                message = "Device token registered successfully",
                data = token
            }
        }
    end))

    -- GET /api/v2/device-tokens - Get all device tokens for current user
    app:get("/api/v2/device-tokens", AuthMiddleware.requireAuth(function(self)
        local user = self.current_user
        local tokens = DeviceTokenQueries.getByUser(user.uuid)

        return {
            status = 200,
            json = {
                data = tokens
            }
        }
    end))

    -- DELETE /api/v2/device-tokens - Remove a device token (logout)
    app:delete("/api/v2/device-tokens", AuthMiddleware.requireAuth(function(self)
        local user = self.current_user
        local data = parse_json_body()

        if not data.fcm_token or data.fcm_token == "" then
            return {
                status = 400,
                json = { error = "fcm_token is required" }
            }
        end

        local deactivated = DeviceTokenQueries.deactivate(data.fcm_token, user.uuid)

        if not deactivated then
            return {
                status = 404,
                json = { error = "Device token not found" }
            }
        end

        return {
            status = 200,
            json = { message = "Device token removed successfully" }
        }
    end))

    -- DELETE /api/v2/device-tokens/all - Remove all device tokens (logout from all devices)
    app:delete("/api/v2/device-tokens/all", AuthMiddleware.requireAuth(function(self)
        local user = self.current_user

        DeviceTokenQueries.deactivateAll(user.uuid)

        return {
            status = 200,
            json = { message = "All device tokens removed successfully" }
        }
    end))

    -- DELETE /api/v2/device-tokens/:uuid - Remove a specific device token by UUID
    app:delete("/api/v2/device-tokens/:uuid", AuthMiddleware.requireAuth(function(self)
        local user = self.current_user
        local token_uuid = self.params.uuid

        local deleted = DeviceTokenQueries.destroy(token_uuid, user.uuid)

        if not deleted then
            return {
                status = 404,
                json = { error = "Device token not found" }
            }
        end

        return {
            status = 200,
            json = { message = "Device token deleted successfully" }
        }
    end))
end
