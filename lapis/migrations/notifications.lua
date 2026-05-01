local schema = require("lapis.db.schema")
local types = schema.types
local db = require("lapis.db")

return {
    -- Create notifications table
    [1] = function()
        -- Check if table already exists
        local existing = db.query([[
            SELECT EXISTS (
                SELECT FROM information_schema.tables
                WHERE table_name = 'notifications'
            ) as exists
        ]])

        if existing and existing[1] and existing[1].exists then
            return -- Table already exists, skip
        end

        schema.create_table("notifications", {
            {"id", types.serial},
            {"uuid", types.varchar({ unique = true })},
            {"user_id", types.foreign_key},
            {"type", types.varchar},  -- order_status_change, order_cancelled, order_shipped, etc
            {"title", types.varchar},
            {"message", types.text},
            {"data", types.text({ null = true })},  -- JSON data for notification context
            {"related_entity_type", types.varchar({ null = true })},  -- order, product, store
            {"related_entity_id", types.varchar({ null = true })},  -- UUID of related entity
            {"is_read", types.boolean({ default = false })},
            {"read_at", types.time({ null = true })},
            {"created_at", types.time},
            "PRIMARY KEY (id)"
        })
    end,

    -- Add indexes for notifications
    [2] = function()
        pcall(function() schema.create_index("notifications", "uuid") end)
        pcall(function() schema.create_index("notifications", "user_id") end)
        pcall(function() schema.create_index("notifications", "type") end)
        pcall(function() schema.create_index("notifications", "is_read") end)
        pcall(function() schema.create_index("notifications", "created_at") end)
        pcall(function() schema.create_index("notifications", "related_entity_type", "related_entity_id") end)
    end,

    -- Create notification preferences table
    [3] = function()
        -- Check if table already exists
        local existing = db.query([[
            SELECT EXISTS (
                SELECT FROM information_schema.tables
                WHERE table_name = 'notification_preferences'
            ) as exists
        ]])

        if existing and existing[1] and existing[1].exists then
            return -- Table already exists, skip
        end

        schema.create_table("notification_preferences", {
            {"id", types.serial},
            {"user_id", types.foreign_key({ unique = true })},
            {"email_order_updates", types.boolean({ default = true })},
            {"email_order_shipped", types.boolean({ default = true })},
            {"email_order_delivered", types.boolean({ default = true })},
            {"email_order_cancelled", types.boolean({ default = true })},
            {"in_app_notifications", types.boolean({ default = true })},
            {"created_at", types.time},
            {"updated_at", types.time},
            "PRIMARY KEY (id)"
        })
    end
}
