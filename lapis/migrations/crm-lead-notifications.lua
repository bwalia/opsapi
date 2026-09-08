--[[
    CRM Lead Notification Settings

    Per-namespace configuration for what happens when a lead is captured
    (typically from a public website form). One row per namespace:

      - notify_admin        email the namespace owner/admin "you got a lead"
      - admin_email         optional override recipient (defaults to owner email)
      - send_confirmation   email the person who submitted the lead
      - telegram_enabled    also push a Telegram alert
      - telegram_bot_token  bot token from @BotFather (owner-provided)
      - telegram_chat_id    target chat id

    Feature-gated under FEATURES.CRM. Idempotent (CREATE TABLE IF NOT EXISTS).
    The bot token is a per-namespace credential the owner sets; the API masks it
    on read (never echoes it back) and only overwrites it when a new value is
    sent — see CrmLeadNotificationQueries.
]]

local db = require("lapis.db")

return {
    [1] = function()
        db.query([[
            CREATE TABLE IF NOT EXISTS crm_lead_notification_settings (
                id BIGSERIAL PRIMARY KEY,
                uuid TEXT UNIQUE NOT NULL,
                namespace_id BIGINT NOT NULL UNIQUE REFERENCES namespaces(id) ON DELETE CASCADE,

                notify_admin BOOLEAN DEFAULT TRUE,
                admin_email TEXT,
                send_confirmation BOOLEAN DEFAULT TRUE,

                telegram_enabled BOOLEAN DEFAULT FALSE,
                telegram_bot_token TEXT,
                telegram_chat_id TEXT,

                created_at TIMESTAMP DEFAULT NOW(),
                updated_at TIMESTAMP DEFAULT NOW()
            )
        ]])
        pcall(function()
            db.query([[CREATE INDEX IF NOT EXISTS crm_lead_notif_ns_idx
                ON crm_lead_notification_settings (namespace_id)]])
        end)
    end,
}
