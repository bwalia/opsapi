--[[
    Workspace email (core): each workspace can send through its own SMTP server
    and override the built-in email templates (docs/BILLING_ENTITLEMENTS.md §10).

      [1] namespace_mail_settings   one row per workspace; password encrypted
      [2] namespace_email_templates a workspace's version of a built-in template
      [3] namespace_smtp_accounts   several named SMTP servers per workspace (one is the default)
          namespace_smtp_routes     which server sends which kind of email (leads, shop, invoices...)
          The single server from [1] becomes the default account, so nothing changes until
          the workspace adds a second one.
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

    [3] = function()
        db.query([[
            CREATE TABLE IF NOT EXISTS namespace_smtp_accounts (
                id BIGSERIAL PRIMARY KEY,
                uuid TEXT NOT NULL UNIQUE,
                namespace_id BIGINT NOT NULL REFERENCES namespaces(id) ON DELETE CASCADE,
                name TEXT NOT NULL CHECK (length(name) BETWEEN 1 AND 80),
                host TEXT NOT NULL,
                port INTEGER NOT NULL DEFAULT 587 CHECK (port BETWEEN 1 AND 65535),
                security TEXT NOT NULL DEFAULT 'starttls' CHECK (security IN ('starttls', 'ssl', 'none')),
                username TEXT,
                password_encrypted TEXT,
                from_email TEXT NOT NULL,
                from_name TEXT,
                reply_to TEXT,
                enabled BOOLEAN NOT NULL DEFAULT TRUE,
                is_default BOOLEAN NOT NULL DEFAULT FALSE,
                last_tested_at TIMESTAMPTZ,
                last_error TEXT,
                updated_by TEXT,
                created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
                updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
                UNIQUE (namespace_id, name)
            )
        ]])
        db.query([[CREATE UNIQUE INDEX IF NOT EXISTS namespace_smtp_accounts_one_default
            ON namespace_smtp_accounts (namespace_id) WHERE is_default]])
        db.query([[
            CREATE TABLE IF NOT EXISTS namespace_smtp_routes (
                namespace_id BIGINT NOT NULL REFERENCES namespaces(id) ON DELETE CASCADE,
                purpose TEXT NOT NULL CHECK (purpose ~ '^[a-z0-9_]{1,40}$'),
                account_id BIGINT NOT NULL REFERENCES namespace_smtp_accounts(id) ON DELETE CASCADE,
                updated_by TEXT,
                updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
                PRIMARY KEY (namespace_id, purpose)
            )
        ]])
        -- The existing single server becomes each workspace's default account.
        db.query([[
            INSERT INTO namespace_smtp_accounts (uuid, namespace_id, name, host, port, security, username,
                password_encrypted, from_email, from_name, reply_to, enabled, is_default, last_tested_at, last_error,
                updated_by, created_at, updated_at)
            SELECT md5(random()::text || clock_timestamp()::text || s.namespace_id::text)::uuid::text, s.namespace_id,
                'Main', s.host, s.port, s.security, s.username, s.password_encrypted, s.from_email, s.from_name,
                s.reply_to, s.enabled, TRUE, s.last_tested_at, s.last_error, s.updated_by, s.created_at, s.updated_at
            FROM namespace_mail_settings s
            WHERE NOT EXISTS (SELECT 1 FROM namespace_smtp_accounts a WHERE a.namespace_id = s.namespace_id)
        ]])
    end,
}
