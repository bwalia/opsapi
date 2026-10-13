--[[
    Shop AI-advisor migrations (FEATURES.SHOP)
    ==========================================

    Links advisor chats to the CRM and records what the customer needs.

      shop_chat_sessions.requirements     what the customer said (goal, models, budget, …)
      shop_chat_sessions.improve_consent  explicit opt-in: may we use this chat to improve advice
      shop_chat_sessions.consent_at       when that choice was made
      shop_chat_sessions.crm_lead_id      the customer's open CRM lead (one per email)

    Registered in migrations.lua as zzs18. Idempotent.
]]

local db = require("lapis.db")

return {
    [1] = function()
        db.query([[ALTER TABLE shop_chat_sessions ADD COLUMN IF NOT EXISTS requirements jsonb NOT NULL DEFAULT '{}'::jsonb]])
        db.query([[ALTER TABLE shop_chat_sessions ADD COLUMN IF NOT EXISTS improve_consent boolean NOT NULL DEFAULT false]])
        db.query([[ALTER TABLE shop_chat_sessions ADD COLUMN IF NOT EXISTS consent_at timestamptz]])
        db.query([[ALTER TABLE shop_chat_sessions ADD COLUMN IF NOT EXISTS crm_lead_id bigint]])
        db.query([[
            CREATE INDEX IF NOT EXISTS shop_chat_sessions_email_idx ON shop_chat_sessions (namespace_id, lower(email))
        ]])
        db.query([[
            CREATE INDEX IF NOT EXISTS crm_leads_ns_lower_email_idx ON crm_leads (namespace_id, lower(email))
        ]])
    end,
}
