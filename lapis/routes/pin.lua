--[[
    PIN Routes (routes/pin.lua)

    Mobile app PIN authentication endpoints.
    All endpoints require JWT authentication (not in public_auth_routes).
    PIN is a 4-digit numeric code stored as a bcrypt hash in users.pin_hash.
]]

local db = require("lapis.db")
local Global = require "helper.global"
local RateLimit = require("middleware.rate-limit")

local PIN_LIMIT = { rate = 5, window = 60, prefix = "auth:pin" } -- 5/min per IP

-- Helper function to parse JSON body
local function parse_json_body()
    local cJson = require("cjson")
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

return function(app)

    -- POST /auth/pin/setup — Create or update PIN
    app:post("/auth/pin/setup", RateLimit.wrap(PIN_LIMIT, function(self)
        if not self.current_user then
            return { status = 401, json = { error = "Authentication required" } }
        end

        local params = parse_json_body()
        local pin = params.pin or self.params.pin

        if not pin or type(pin) ~= "string" then
            return { status = 400, json = { error = "PIN is required" } }
        end

        -- Validate 4-digit format
        if not pin:match("^%d%d%d%d$") then
            return { status = 400, json = { error = "PIN must be exactly 4 digits" } }
        end

        -- Hash with bcrypt
        local pin_hash = Global.hashPassword(pin)

        -- Store in users table
        local user_uuid = self.current_user.uuid
        db.update("users", { pin_hash = pin_hash }, { uuid = user_uuid })

        ngx.log(ngx.NOTICE, "[PIN] PIN set for user: ", user_uuid)

        return {
            status = 200,
            json = {
                message = "PIN set successfully",
                has_pin = true,
            }
        }
    end))

    -- POST /auth/pin/verify — Server-side PIN verification (for new device flow)
    app:post("/auth/pin/verify", RateLimit.wrap(PIN_LIMIT, function(self)
        if not self.current_user then
            return { status = 401, json = { error = "Authentication required" } }
        end

        local params = parse_json_body()
        local pin = params.pin or self.params.pin

        if not pin or type(pin) ~= "string" then
            return { status = 400, json = { error = "PIN is required" } }
        end

        local user_uuid = self.current_user.uuid
        local rows = db.select("pin_hash FROM users WHERE uuid = ?", user_uuid)

        if not rows or #rows == 0 or not rows[1].pin_hash then
            return { status = 400, json = { error = "PIN not set up. Please set up your PIN first." } }
        end

        local is_valid = Global.matchPassword(pin, rows[1].pin_hash)

        if not is_valid then
            ngx.log(ngx.NOTICE, "[PIN] Invalid PIN attempt for user: ", user_uuid)
            return { status = 401, json = { error = "Invalid PIN" } }
        end

        return {
            status = 200,
            json = { verified = true }
        }
    end))

    -- GET /auth/pin/status — Check if user has a PIN set
    app:get("/auth/pin/status", function(self)
        if not self.current_user then
            return { status = 401, json = { error = "Authentication required" } }
        end

        local user_uuid = self.current_user.uuid
        local rows = db.select("pin_hash FROM users WHERE uuid = ?", user_uuid)

        local has_pin = rows and #rows > 0 and rows[1].pin_hash ~= nil and true or false

        return {
            status = 200,
            json = { has_pin = has_pin }
        }
    end)

end
