--[[
    Push Notifications Migration
    ============================

    Creates the device_tokens table for storing FCM tokens for push notifications.
    Supports both iOS and Android devices via Firebase Cloud Messaging.
]]

local schema = require("lapis.db.schema")
local types = schema.types
local db = require("lapis.db")

-- Helper to check if table exists
local function table_exists(table_name)
    local result = db.query([[
        SELECT EXISTS (
            SELECT FROM information_schema.tables
            WHERE table_name = ?
        ) as exists
    ]], table_name)
    return result[1] and result[1].exists
end

return {
    -- ========================================
    -- [1] Create device_tokens table
    -- ========================================
    [1] = function()
        if table_exists("device_tokens") then return end

        schema.create_table("device_tokens", {
            { "id", types.serial },
            { "uuid", types.varchar({ unique = true }) },
            { "user_uuid", types.varchar },

            -- FCM Token
            { "fcm_token", types.text },

            -- Device Information
            { "device_type", types.varchar({ null = true }) },  -- 'ios' or 'android'
            { "device_name", types.varchar({ null = true }) },

            -- Status
            { "is_active", "boolean DEFAULT true" },

            -- Timestamps
            { "created_at", "timestamp DEFAULT CURRENT_TIMESTAMP" },
            { "updated_at", "timestamp DEFAULT CURRENT_TIMESTAMP" },

            "PRIMARY KEY (id)",
            "FOREIGN KEY (user_uuid) REFERENCES users(uuid) ON DELETE CASCADE"
        })
    end,

    -- ========================================
    -- [2] Create device_tokens indexes
    -- ========================================
    [2] = function()
        pcall(function() schema.create_index("device_tokens", "uuid") end)
        pcall(function() schema.create_index("device_tokens", "user_uuid") end)
        pcall(function() schema.create_index("device_tokens", "fcm_token") end)
        pcall(function() schema.create_index("device_tokens", "is_active") end)

        -- Composite index for common queries
        pcall(function()
            db.query([[
                CREATE INDEX device_tokens_user_active_idx
                ON device_tokens (user_uuid, is_active)
                WHERE is_active = true
            ]])
        end)
    end,
}
