local VaultExternalProviderModel = require("models.VaultExternalProviderModel")
local VaultSyncMappingModel = require("models.VaultSyncMappingModel")
local VaultSyncLogModel = require("models.VaultSyncLogModel")
local Global = require("helper.global")
local db = require("lapis.db")
local cjson = require("cjson")

local VaultProviderQueries = {}

-- =============================================================================
-- PROVIDERS
-- =============================================================================

function VaultProviderQueries.createProvider(params)
    params.uuid = params.uuid or Global.generateUUID()
    params.created_at = db.raw("NOW()")
    params.updated_at = db.raw("NOW()")

    if type(params.config) == "table" then
        params.config = cjson.encode(params.config)
    end

    return VaultExternalProviderModel:create(params, { returning = "*" })
end

function VaultProviderQueries.listProviders(vault_id)
    local sql = [[
        SELECT * FROM vault_external_providers
        WHERE vault_id = ? AND deleted_at IS NULL
        ORDER BY created_at DESC
    ]]
    return db.query(sql, vault_id)
end

function VaultProviderQueries.getProvider(uuid)
    local result = db.query("SELECT * FROM vault_external_providers WHERE uuid = ? AND deleted_at IS NULL", uuid)
    return result and result[1] or nil
end

function VaultProviderQueries.updateProvider(uuid, params)
    params.updated_at = db.raw("NOW()")
    if type(params.config) == "table" then
        params.config = cjson.encode(params.config)
    end

    local provider = VaultExternalProviderModel:find({ uuid = uuid })
    if not provider then return nil, "Provider not found" end
    return provider:update(params, { returning = "*" })
end

function VaultProviderQueries.deleteProvider(uuid)
    return db.query("UPDATE vault_external_providers SET deleted_at = NOW() WHERE uuid = ? AND deleted_at IS NULL", uuid)
end

function VaultProviderQueries.updateSyncStatus(provider_id, status, error_msg)
    return db.query([[
        UPDATE vault_external_providers
        SET status = ?, last_sync_at = NOW(), last_sync_status = ?,
            last_sync_error = ?, updated_at = NOW()
        WHERE id = ?
    ]], status, status, error_msg, provider_id)
end

-- =============================================================================
-- SYNC MAPPINGS
-- =============================================================================

function VaultProviderQueries.createMapping(params)
    params.uuid = params.uuid or Global.generateUUID()
    params.created_at = db.raw("NOW()")
    params.updated_at = db.raw("NOW()")
    return VaultSyncMappingModel:create(params, { returning = "*" })
end

function VaultProviderQueries.getMappings(provider_id)
    return db.query("SELECT * FROM vault_sync_mappings WHERE provider_id = ? ORDER BY external_path, external_key", provider_id)
end

function VaultProviderQueries.updateMapping(uuid, params)
    params.updated_at = db.raw("NOW()")
    local mapping = VaultSyncMappingModel:find({ uuid = uuid })
    if not mapping then return nil, "Mapping not found" end
    return mapping:update(params, { returning = "*" })
end

function VaultProviderQueries.deleteMapping(uuid)
    return db.query("DELETE FROM vault_sync_mappings WHERE uuid = ?", uuid)
end

function VaultProviderQueries.getMappingByExternalPath(provider_id, external_path, external_key)
    local result = db.query([[
        SELECT * FROM vault_sync_mappings
        WHERE provider_id = ? AND external_path = ? AND external_key = ?
    ]], provider_id, external_path, external_key)
    return result and result[1] or nil
end

-- =============================================================================
-- SYNC OPERATIONS
-- =============================================================================

function VaultProviderQueries.testConnection(provider_type, config)
    local ok_vp, VaultProviders = pcall(require, "lib.vault-providers")
    if not ok_vp then return false, "Vault providers module not available" end

    local provider, err = VaultProviders.create(provider_type, config)
    if not provider then return false, err end

    local connected, conn_err = provider:connect()
    if not connected then return false, conn_err end

    local test_ok, test_err = provider:testConnection()
    return test_ok, test_err
end

function VaultProviderQueries.syncImport(provider_record, vault_key, encrypt_fn)
    local start_time = ngx.now()
    local results = { processed = 0, created = 0, updated = 0, failed = 0, errors = {} }

    local ok_vp, VaultProviders = pcall(require, "lib.vault-providers")
    if not ok_vp then return nil, "Vault providers module not available" end

    local config = type(provider_record.config) == "string" and cjson.decode(provider_record.config) or provider_record.config or {}
    local provider, err = VaultProviders.create(provider_record.provider_type, config)
    if not provider then return nil, "Failed to create provider: " .. (err or "unknown") end

    local connected, conn_err = provider:connect()
    if not connected then
        VaultProviderQueries.updateSyncStatus(provider_record.id, "error", conn_err)
        return nil, "Connection failed: " .. (conn_err or "unknown")
    end

    VaultProviderQueries.updateSyncStatus(provider_record.id, "syncing", nil)

    -- List external secrets
    local secrets, list_err = provider:listSecrets("")
    if not secrets then
        VaultProviderQueries.updateSyncStatus(provider_record.id, "error", list_err)
        return nil, "Failed to list secrets: " .. (list_err or "unknown")
    end

    for _, ext_secret in ipairs(secrets) do
        results.processed = results.processed + 1
        local ok_import, import_err = pcall(function()
            -- Get the secret value
            local secret_data, get_err = provider:getSecret(ext_secret.path, ext_secret.key)
            if not secret_data then error("Failed to get: " .. (get_err or "unknown")) end

            -- Check if mapping exists
            local mapping = VaultProviderQueries.getMappingByExternalPath(
                provider_record.id, ext_secret.path, ext_secret.key)

            local local_name = ext_secret.key:gsub("[/\\]", "_")

            if mapping and mapping.local_secret_id then
                -- Update existing secret
                if encrypt_fn then
                    encrypt_fn(mapping.local_secret_id, secret_data.value)
                end
                VaultProviderQueries.updateMapping(mapping.uuid, {
                    sync_status = "synced",
                    last_synced_at = db.raw("NOW()"),
                    external_version = ext_secret.version,
                })
                results.updated = results.updated + 1
            else
                -- Create new mapping (secret creation handled by caller)
                VaultProviderQueries.createMapping({
                    provider_id = provider_record.id,
                    external_path = ext_secret.path or "",
                    external_key = ext_secret.key,
                    local_name = local_name,
                    secret_type = "generic",
                    sync_status = "synced",
                    last_synced_at = db.raw("NOW()"),
                    external_version = ext_secret.version,
                })
                results.created = results.created + 1
            end
        end)

        if not ok_import then
            results.failed = results.failed + 1
            results.errors[#results.errors + 1] = {
                key = ext_secret.key,
                error = tostring(import_err),
            }
        end
    end

    local duration = math.floor((ngx.now() - start_time) * 1000)
    local final_status = results.failed > 0 and "error" or "active"

    VaultProviderQueries.updateSyncStatus(provider_record.id, final_status,
        results.failed > 0 and (results.failed .. " secrets failed to sync") or nil)

    -- Update synced count
    db.query("UPDATE vault_external_providers SET secrets_synced_count = ? WHERE id = ?",
        results.created + results.updated, provider_record.id)

    -- Log sync
    VaultProviderQueries.logSync({
        provider_id = provider_record.id,
        namespace_id = provider_record.namespace_id,
        action = results.failed > 0 and "sync_completed" or "sync_completed",
        secrets_processed = results.processed,
        secrets_created = results.created,
        secrets_updated = results.updated,
        secrets_failed = results.failed,
        duration_ms = duration,
        details = cjson.encode(results),
    })

    return results
end

-- =============================================================================
-- SYNC LOGS
-- =============================================================================

function VaultProviderQueries.logSync(params)
    params.uuid = params.uuid or Global.generateUUID()
    params.created_at = db.raw("NOW()")
    if type(params.details) ~= "string" and params.details then
        params.details = cjson.encode(params.details)
    end
    return VaultSyncLogModel:create(params)
end

function VaultProviderQueries.getSyncLogs(provider_id, params)
    params = params or {}
    local page = tonumber(params.page) or 1
    local per_page = tonumber(params.per_page) or 20
    local offset = (page - 1) * per_page

    local count_result = db.query("SELECT COUNT(*) as total FROM vault_sync_logs WHERE provider_id = ?", provider_id)
    local total = count_result and count_result[1] and tonumber(count_result[1].total) or 0

    local logs = db.query([[
        SELECT * FROM vault_sync_logs WHERE provider_id = ?
        ORDER BY created_at DESC LIMIT ? OFFSET ?
    ]], provider_id, per_page, offset)

    return {
        data = logs or {},
        total = total,
        page = page,
        per_page = per_page,
        total_pages = math.ceil(total / per_page),
    }
end

-- =============================================================================
-- BULK OPERATIONS
-- =============================================================================

function VaultProviderQueries.parseEnvContent(content)
    local ok_env, EnvProvider = pcall(require, "lib.vault-providers.env-file")
    if not ok_env then return nil, ".env provider not available" end

    local provider = EnvProvider:new({ file_content = content, format = "dotenv" })
    local secrets, err = provider:listSecrets("")
    if not secrets then return nil, err end

    local result = {}
    for _, s in ipairs(secrets) do
        local data, get_err = provider:getSecret("", s.key)
        if data then
            result[#result + 1] = { key = s.key, value = data.value }
        end
    end
    return result
end

function VaultProviderQueries.exportAsEnv(secrets_table)
    local ok_env, EnvProvider = pcall(require, "lib.vault-providers.env-file")
    if not ok_env then return nil, ".env provider not available" end

    local provider = EnvProvider:new({})
    return provider:exportDotenv(secrets_table)
end

function VaultProviderQueries.exportAsJson(secrets_table)
    return cjson.encode(secrets_table)
end

-- =============================================================================
-- SECRET ROTATION
-- =============================================================================

function VaultProviderQueries.getExpiringSecrets(vault_id, days_ahead)
    days_ahead = days_ahead or 30
    return db.query([[
        SELECT * FROM namespace_vault_secrets
        WHERE vault_id = ? AND deleted_at IS NULL
          AND expires_at IS NOT NULL
          AND expires_at <= NOW() + (? || ' days')::interval
        ORDER BY expires_at ASC
    ]], vault_id, tostring(days_ahead))
end

return VaultProviderQueries
