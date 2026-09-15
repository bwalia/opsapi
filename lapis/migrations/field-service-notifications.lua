--[[
    Field Service — repair in-app notifications

    NotificationHelper.create and routes/notifications expect an in-app shape
    (user_id, title, is_read, related_entity_*), but this deployment's
    `notifications` table only had the outbound-email shape (recipient/subject/
    template_name). Add the in-app columns so the bell works and field-service
    can notify an engineer when a job is assigned. IF NOT EXISTS keeps it safe
    where the columns already exist.

    Feature-gated under FEATURES.FIELD_SERVICE.
]]

local db = require("lapis.db")

local function safe(sql)
    pcall(function() db.query(sql) end)
end

return {
    -- [1] in-app notification columns   (891)
    [1] = function()
        db.query([[
            ALTER TABLE notifications
                ADD COLUMN IF NOT EXISTS user_id BIGINT,
                ADD COLUMN IF NOT EXISTS title TEXT,
                ADD COLUMN IF NOT EXISTS is_read BOOLEAN DEFAULT FALSE,
                ADD COLUMN IF NOT EXISTS related_entity_type TEXT,
                ADD COLUMN IF NOT EXISTS related_entity_id BIGINT,
                ADD COLUMN IF NOT EXISTS data TEXT
        ]])
        -- The email-queue columns are NOT NULL; in-app notifications don't have
        -- a recipient address or send status, so relax them (email rows still
        -- set their own values).
        safe([[ALTER TABLE notifications ALTER COLUMN recipient DROP NOT NULL]])
        safe([[ALTER TABLE notifications ALTER COLUMN status DROP NOT NULL]])
        safe([[CREATE INDEX IF NOT EXISTS notifications_user_unread_idx
               ON notifications (user_id, is_read) WHERE user_id IS NOT NULL]])
    end,
}
