--[[
    Workspace email (core): each workspace can send through its own SMTP server
    and override the built-in email templates (docs/BILLING_ENTITLEMENTS.md §10).

      [1] namespace_mail_settings   one row per workspace; password encrypted
      [2] namespace_email_templates a workspace's version of a built-in template
]]

local db = require("lapis.db")

return {
    [1] = function()
        db.query([[
            CREATE TABLE IF NOT EXISTS namespace_mail_settings (
                id BIGSERIAL PRIMARY KEY,
                namespace_id BIGINT NOT NULL UNIQUE REFERENCES namespaces(id) ON DELETE CASCADE,
                host TEXT NOT NULL,
                port INTEGER NOT NULL DEFAULT 587 CHECK (port BETWEEN 1 AND 65535),
                security TEXT NOT NULL DEFAULT 'starttls' CHECK (security IN ('starttls', 'ssl', 'none')),
                username TEXT,
                password_encrypted TEXT,
                from_email TEXT NOT NULL,
                from_name TEXT,
                reply_to TEXT,
                enabled BOOLEAN NOT NULL DEFAULT TRUE,
                last_tested_at TIMESTAMPTZ,
                last_error TEXT,
                updated_by TEXT,
                created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
                updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
            )
        ]])
    end,

    [2] = function()
        db.query([[
            CREATE TABLE IF NOT EXISTS namespace_email_templates (
                id BIGSERIAL PRIMARY KEY,
                namespace_id BIGINT NOT NULL REFERENCES namespaces(id) ON DELETE CASCADE,
                template_key TEXT NOT NULL CHECK (template_key ~ '^[a-z0-9_.]{1,80}$'),
                subject TEXT NOT NULL,
                html TEXT NOT NULL,
                updated_by TEXT,
                created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
                updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
                UNIQUE (namespace_id, template_key)
            )
        ]])
    end,
}
