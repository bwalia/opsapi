--[[
    Domain Management Migrations
    ============================

    Central, namespace-scoped domain registry with:
      - domains               : the domain records (registration + SSL expiry tracking)
      - domain_credentials    : provider API tokens (e.g. Cloudflare), AES-encrypted at rest
      - domain_sync_configs   : k3s-job sync destinations (push domains.json to a GitHub repo)

    Gated on FEATURES.SERVICES in migrations.lua (shares the infrastructure remit;
    no dedicated project code). Every table carries namespace_id and is filtered by
    it in queries (platform admins get a cross-namespace view).

    Secrets policy:
      - Cloudflare API tokens live in domain_credentials.encrypted_secret, encrypted
        with Global.encryptSecret (AES via OPENSSL_SECRET_KEY) so the backend can
        decrypt them server-side to call the Cloudflare API. Never stored plaintext.
      - The GitHub token used by the generated k3s CronJob is NOT stored here — the
        sync config only references a Kubernetes Secret name (populated by ESO / the
        external vault). See helper/domain-sync-manifest.lua.
]]

local db = require("lapis.db")

-- NOTE: scope to public BASE TABLEs. A bare information_schema.tables check on
-- table_name='domains' also matches the built-in information_schema.domains view,
-- which would make this guard skip creating our real table. to_regclass is the
-- unambiguous test for "does public.<name> exist as a relation".
local function table_exists(name)
    local result = db.query("SELECT to_regclass('public.' || ?) IS NOT NULL AS exists", name)
    return result and result[1] and result[1].exists
end

return {
    -- ========================================
    -- [1] domains — the core registry
    -- ========================================
    [1] = function()
        if table_exists("domains") then return end

        db.query([[
            CREATE TABLE IF NOT EXISTS domains (
                id BIGSERIAL PRIMARY KEY,
                uuid TEXT UNIQUE NOT NULL,
                namespace_id BIGINT NOT NULL REFERENCES namespaces(id) ON DELETE CASCADE,

                -- Identity
                domain_name TEXT NOT NULL,
                registrar TEXT,
                dns_provider TEXT DEFAULT 'cloudflare',
                cloudflare_zone_id TEXT,

                -- Lifecycle status: active | expiring_soon | expired | error | pending
                status TEXT DEFAULT 'active',

                -- Registration (WHOIS/RDAP) expiry
                registration_expires_at TIMESTAMP,
                registrar_status TEXT,

                -- SSL / TLS certificate expiry (live handshake)
                ssl_expires_at TIMESTAMP,
                ssl_issuer TEXT,

                -- Monitoring bookkeeping
                last_checked_at TIMESTAMP,
                last_check_error TEXT,
                alert_threshold_days INTEGER DEFAULT 30,
                auto_renew BOOLEAN DEFAULT FALSE,

                -- Ownership / free-form
                owner_user_uuid TEXT,
                notes TEXT,
                metadata JSONB DEFAULT '{}',

                created_at TIMESTAMP DEFAULT NOW(),
                updated_at TIMESTAMP DEFAULT NOW(),
                deleted_at TIMESTAMP,

                CONSTRAINT domains_namespace_domain_unique UNIQUE (namespace_id, domain_name)
            )
        ]])

        pcall(function() db.query([[CREATE INDEX domains_namespace_status_idx ON domains (namespace_id, status)]]) end)
        pcall(function() db.query([[CREATE INDEX domains_uuid_idx ON domains (uuid)]]) end)
        pcall(function() db.query([[CREATE INDEX domains_domain_name_idx ON domains (domain_name)]]) end)
        pcall(function() db.query([[CREATE INDEX domains_reg_expires_idx ON domains (registration_expires_at)]]) end)
        pcall(function() db.query([[CREATE INDEX domains_ssl_expires_idx ON domains (ssl_expires_at)]]) end)
        pcall(function() db.query([[CREATE INDEX domains_owner_user_uuid_idx ON domains (owner_user_uuid)]]) end)
    end,

    -- ========================================
    -- [2] domain_credentials — encrypted provider tokens (Cloudflare, ...)
    -- ========================================
    [2] = function()
        if table_exists("domain_credentials") then return end

        db.query([[
            CREATE TABLE IF NOT EXISTS domain_credentials (
                id BIGSERIAL PRIMARY KEY,
                uuid TEXT UNIQUE NOT NULL,
                namespace_id BIGINT NOT NULL REFERENCES namespaces(id) ON DELETE CASCADE,

                provider TEXT NOT NULL DEFAULT 'cloudflare',
                label TEXT,

                -- AES-encrypted (Global.encryptSecret) — NEVER plaintext.
                encrypted_secret TEXT NOT NULL,

                -- Non-secret provider metadata
                account_id TEXT,
                email TEXT,
                metadata JSONB DEFAULT '{}',

                created_at TIMESTAMP DEFAULT NOW(),
                updated_at TIMESTAMP DEFAULT NOW(),

                CONSTRAINT domain_credentials_namespace_provider_unique UNIQUE (namespace_id, provider)
            )
        ]])

        pcall(function() db.query([[CREATE INDEX domain_credentials_namespace_idx ON domain_credentials (namespace_id)]]) end)
        pcall(function() db.query([[CREATE INDEX domain_credentials_uuid_idx ON domain_credentials (uuid)]]) end)
    end,

    -- ========================================
    -- [3] domain_sync_configs — k3s sync destinations
    -- ========================================
    [3] = function()
        if table_exists("domain_sync_configs") then return end

        db.query([[
            CREATE TABLE IF NOT EXISTS domain_sync_configs (
                id BIGSERIAL PRIMARY KEY,
                uuid TEXT UNIQUE NOT NULL,
                namespace_id BIGINT NOT NULL REFERENCES namespaces(id) ON DELETE CASCADE,

                name TEXT NOT NULL,
                destination_type TEXT NOT NULL DEFAULT 'github',

                -- GitHub destination
                github_repo TEXT,          -- owner/repo
                github_branch TEXT DEFAULT 'main',
                file_path TEXT DEFAULT 'domains.json',
                commit_author_name TEXT DEFAULT 'opsapi-domain-sync',
                commit_author_email TEXT DEFAULT 'domain-sync@opsapi',

                -- Reference (NOT the token) to a Kubernetes Secret populated by ESO / the vault.
                -- The same Secret carries the GitHub PAT and the opsapi machine token
                -- (two keys) so the generated CronJob holds NO secret literals.
                github_token_secret_ref TEXT,
                github_token_secret_key TEXT DEFAULT 'github-token',

                -- Where the CronJob fetches the live domain export from, and which
                -- key in the same Secret holds the opsapi bearer token for that call.
                opsapi_base_url TEXT,
                opsapi_token_secret_key TEXT DEFAULT 'opsapi-token',

                -- Cron schedule for the generated k3s CronJob
                schedule TEXT DEFAULT '0 3 * * *',

                is_enabled BOOLEAN DEFAULT TRUE,
                last_synced_at TIMESTAMP,
                last_status TEXT,          -- success | error | never
                last_error TEXT,
                metadata JSONB DEFAULT '{}',

                created_at TIMESTAMP DEFAULT NOW(),
                updated_at TIMESTAMP DEFAULT NOW(),
                deleted_at TIMESTAMP
            )
        ]])

        pcall(function() db.query([[CREATE INDEX domain_sync_configs_namespace_idx ON domain_sync_configs (namespace_id)]]) end)
        pcall(function() db.query([[CREATE INDEX domain_sync_configs_uuid_idx ON domain_sync_configs (uuid)]]) end)
    end,
}
