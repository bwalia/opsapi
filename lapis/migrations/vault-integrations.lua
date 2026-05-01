--[[
    Vault External Provider Integrations Migrations
    ================================================

    Enables the opsapi vault to sync/import secrets from external providers:
    - HashiCorp Vault
    - AWS Secrets Manager
    - Azure Key Vault
    - GCP Secret Manager
    - Kubernetes Secrets
    - .env / dotenv files

    Tables:
    - vault_external_providers: Provider configurations per vault
    - vault_sync_mappings: Maps external secrets to local vault secrets
    - vault_sync_logs: Audit trail for sync operations
]]

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
    -- [1] Create vault_external_providers table
    -- ========================================
    [1] = function()
        if table_exists("vault_external_providers") then return end

        db.query([[
            CREATE TABLE vault_external_providers (
                id BIGSERIAL PRIMARY KEY,
                uuid TEXT UNIQUE NOT NULL,
                namespace_id BIGINT NOT NULL REFERENCES namespaces(id) ON DELETE CASCADE,
                vault_id BIGINT NOT NULL REFERENCES namespace_secret_vaults(id) ON DELETE CASCADE,
                provider_type TEXT NOT NULL CHECK (provider_type IN (
                    'hashicorp_vault',
                    'aws_secrets_manager',
                    'azure_key_vault',
                    'gcp_secret_manager',
                    'kubernetes',
                    'env_file',
                    'dotenv'
                )),
                name TEXT NOT NULL,
                description TEXT,
                config JSONB NOT NULL DEFAULT '{}',
                credentials_encrypted TEXT,
                credentials_iv TEXT,
                credentials_tag TEXT,
                status TEXT DEFAULT 'active' CHECK (status IN ('active', 'inactive', 'error', 'syncing')),
                last_sync_at TIMESTAMP,
                last_sync_status TEXT,
                last_sync_error TEXT,
                sync_direction TEXT DEFAULT 'import' CHECK (sync_direction IN ('import', 'export', 'bidirectional')),
                sync_frequency TEXT DEFAULT 'manual' CHECK (sync_frequency IN ('manual', 'hourly', 'daily', 'weekly')),
                auto_sync BOOLEAN DEFAULT false,
                secrets_synced_count INTEGER DEFAULT 0,
                created_by_uuid TEXT NOT NULL,
                created_at TIMESTAMP DEFAULT NOW(),
                updated_at TIMESTAMP DEFAULT NOW(),
                deleted_at TIMESTAMP
            )
        ]])

        -- Indexes
        pcall(function()
            db.query([[
                CREATE INDEX vault_external_providers_ns_vault_idx
                ON vault_external_providers (namespace_id, vault_id)
            ]])
        end)

        pcall(function()
            db.query([[
                CREATE INDEX vault_external_providers_provider_type_idx
                ON vault_external_providers (provider_type)
            ]])
        end)

        pcall(function()
            db.query([[
                CREATE INDEX vault_external_providers_status_idx
                ON vault_external_providers (status)
            ]])
        end)
    end,

    -- ========================================
    -- [2] Create vault_sync_mappings table
    -- ========================================
    [2] = function()
        if table_exists("vault_sync_mappings") then return end

        db.query([[
            CREATE TABLE vault_sync_mappings (
                id BIGSERIAL PRIMARY KEY,
                uuid TEXT UNIQUE NOT NULL,
                provider_id BIGINT NOT NULL REFERENCES vault_external_providers(id) ON DELETE CASCADE,
                local_secret_id BIGINT DEFAULT NULL REFERENCES namespace_vault_secrets(id) ON DELETE SET NULL,
                external_path TEXT NOT NULL,
                external_key TEXT NOT NULL,
                local_name TEXT NOT NULL,
                local_folder_id BIGINT DEFAULT NULL REFERENCES namespace_vault_folders(id) ON DELETE SET NULL,
                secret_type TEXT DEFAULT 'generic',
                sync_status TEXT DEFAULT 'pending' CHECK (sync_status IN ('pending', 'synced', 'error', 'conflict')),
                last_synced_at TIMESTAMP,
                last_sync_error TEXT,
                external_version TEXT,
                auto_rotate BOOLEAN DEFAULT false,
                created_at TIMESTAMP DEFAULT NOW(),
                updated_at TIMESTAMP DEFAULT NOW()
            )
        ]])

        -- Unique mapping per provider + external path + key
        pcall(function()
            db.query([[
                CREATE UNIQUE INDEX vault_sync_mappings_provider_path_key_idx
                ON vault_sync_mappings (provider_id, external_path, external_key)
            ]])
        end)

        pcall(function()
            db.query([[
                CREATE INDEX vault_sync_mappings_local_secret_idx
                ON vault_sync_mappings (local_secret_id)
            ]])
        end)
    end,

    -- ========================================
    -- [3] Create vault_sync_logs table
    -- ========================================
    [3] = function()
        if table_exists("vault_sync_logs") then return end

        db.query([[
            CREATE TABLE vault_sync_logs (
                id BIGSERIAL PRIMARY KEY,
                uuid TEXT UNIQUE NOT NULL,
                provider_id BIGINT NOT NULL REFERENCES vault_external_providers(id) ON DELETE CASCADE,
                namespace_id BIGINT NOT NULL,
                action TEXT NOT NULL CHECK (action IN (
                    'sync_started',
                    'sync_completed',
                    'sync_failed',
                    'secret_imported',
                    'secret_exported',
                    'secret_updated',
                    'secret_deleted',
                    'conflict_detected'
                )),
                secrets_processed INTEGER DEFAULT 0,
                secrets_created INTEGER DEFAULT 0,
                secrets_updated INTEGER DEFAULT 0,
                secrets_failed INTEGER DEFAULT 0,
                error_message TEXT,
                details JSONB DEFAULT '{}',
                duration_ms INTEGER,
                created_at TIMESTAMP DEFAULT NOW()
            )
        ]])

        pcall(function()
            db.query([[
                CREATE INDEX vault_sync_logs_provider_id_idx
                ON vault_sync_logs (provider_id)
            ]])
        end)

        pcall(function()
            db.query([[
                CREATE INDEX vault_sync_logs_namespace_id_idx
                ON vault_sync_logs (namespace_id)
            ]])
        end)

        pcall(function()
            db.query([[
                CREATE INDEX vault_sync_logs_created_at_brin
                ON vault_sync_logs USING BRIN (created_at)
            ]])
        end)
    end,
}
