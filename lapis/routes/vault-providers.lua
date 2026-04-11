local cjson = require("cjson")
local AuthMiddleware = require("middleware.auth")
local NamespaceMiddleware = require("middleware.namespace")
local VaultProviderQueries = require("queries.VaultProviderQueries")

return function(app)

    local function parse_json_body()
        ngx.req.read_body()
        local body = ngx.req.get_body_data()
        if not body or body == "" then return {} end
        local ok, data = pcall(cjson.decode, body)
        return ok and data or {}
    end

    local function api_response(status, data, error_msg)
        if error_msg then
            return { status = status, json = { success = false, error = error_msg } }
        end
        return { status = status, json = { success = true, data = data } }
    end

    local function get_vault_key(self)
        return self.req.headers["X-Vault-Key"] or self.req.headers["x-vault-key"]
    end

    -- =========================================================================
    -- PROVIDER CRUD
    -- =========================================================================

    -- List providers
    app:get("/api/v2/vault/providers", AuthMiddleware.requireAuth(
        NamespaceMiddleware.requireNamespace(function(self)
            local vault_key = get_vault_key(self)
            if not vault_key then return api_response(401, nil, "Vault key required (X-Vault-Key header)") end

            -- Get user's vault
            local ok_svq, SecretVaultQueries = pcall(require, "queries.SecretVaultQueries")
            if not ok_svq then return api_response(500, nil, "Vault module not available") end

            local vault = SecretVaultQueries.getVault(self.namespace.id, self.current_user.id)
            if not vault then return api_response(404, nil, "No vault found") end

            local providers = VaultProviderQueries.listProviders(vault.id)
            return api_response(200, providers)
        end)
    ))

    -- Create provider
    app:post("/api/v2/vault/providers", AuthMiddleware.requireAuth(
        NamespaceMiddleware.requireNamespace(function(self)
            local vault_key = get_vault_key(self)
            if not vault_key then return api_response(401, nil, "Vault key required") end

            local data = parse_json_body()
            if not data.provider_type then return api_response(400, nil, "provider_type is required") end
            if not data.name then return api_response(400, nil, "name is required") end

            local ok_svq, SecretVaultQueries = pcall(require, "queries.SecretVaultQueries")
            if not ok_svq then return api_response(500, nil, "Vault module not available") end

            local vault = SecretVaultQueries.getVault(self.namespace.id, self.current_user.id)
            if not vault then return api_response(404, nil, "No vault found") end

            local provider = VaultProviderQueries.createProvider({
                namespace_id = self.namespace.id,
                vault_id = vault.id,
                provider_type = data.provider_type,
                name = data.name,
                description = data.description,
                config = data.config or {},
                sync_direction = data.sync_direction or "import",
                sync_frequency = data.sync_frequency or "manual",
                auto_sync = data.auto_sync or false,
                created_by_uuid = self.current_user.uuid,
            })

            return api_response(201, provider)
        end)
    ))

    -- Get provider
    app:get("/api/v2/vault/providers/:uuid", AuthMiddleware.requireAuth(
        NamespaceMiddleware.requireNamespace(function(self)
            local provider = VaultProviderQueries.getProvider(self.params.uuid)
            if not provider then return api_response(404, nil, "Provider not found") end
            return api_response(200, provider)
        end)
    ))

    -- Update provider
    app:put("/api/v2/vault/providers/:uuid", AuthMiddleware.requireAuth(
        NamespaceMiddleware.requireNamespace(function(self)
            local data = parse_json_body()
            local provider, err = VaultProviderQueries.updateProvider(self.params.uuid, data)
            if not provider then return api_response(404, nil, err or "Provider not found") end
            return api_response(200, provider)
        end)
    ))

    -- Delete provider
    app:delete("/api/v2/vault/providers/:uuid", AuthMiddleware.requireAuth(
        NamespaceMiddleware.requireNamespace(function(self)
            VaultProviderQueries.deleteProvider(self.params.uuid)
            return api_response(200, { deleted = true })
        end)
    ))

    -- =========================================================================
    -- CONNECTION TEST
    -- =========================================================================

    app:post("/api/v2/vault/providers/test-connection", AuthMiddleware.requireAuth(
        NamespaceMiddleware.requireNamespace(function(self)
            local data = parse_json_body()
            if not data.provider_type then return api_response(400, nil, "provider_type required") end
            if not data.config then return api_response(400, nil, "config required") end

            local success, err = VaultProviderQueries.testConnection(data.provider_type, data.config)
            if success then
                return api_response(200, { connected = true, message = "Connection successful" })
            else
                return api_response(200, { connected = false, error = err or "Connection failed" })
            end
        end)
    ))

    -- =========================================================================
    -- SYNC OPERATIONS
    -- =========================================================================

    -- Trigger sync
    app:post("/api/v2/vault/providers/:uuid/sync", AuthMiddleware.requireAuth(
        NamespaceMiddleware.requireNamespace(function(self)
            local vault_key = get_vault_key(self)
            if not vault_key then return api_response(401, nil, "Vault key required") end

            local provider = VaultProviderQueries.getProvider(self.params.uuid)
            if not provider then return api_response(404, nil, "Provider not found") end

            local results, err = VaultProviderQueries.syncImport(provider, vault_key)
            if not results then return api_response(500, nil, err or "Sync failed") end

            return api_response(200, results)
        end)
    ))

    -- List sync mappings
    app:get("/api/v2/vault/providers/:uuid/mappings", AuthMiddleware.requireAuth(
        NamespaceMiddleware.requireNamespace(function(self)
            local provider = VaultProviderQueries.getProvider(self.params.uuid)
            if not provider then return api_response(404, nil, "Provider not found") end

            local mappings = VaultProviderQueries.getMappings(provider.id)
            return api_response(200, mappings)
        end)
    ))

    -- Sync logs
    app:get("/api/v2/vault/providers/:uuid/logs", AuthMiddleware.requireAuth(
        NamespaceMiddleware.requireNamespace(function(self)
            local provider = VaultProviderQueries.getProvider(self.params.uuid)
            if not provider then return api_response(404, nil, "Provider not found") end

            local result = VaultProviderQueries.getSyncLogs(provider.id, {
                page = self.params.page,
                per_page = self.params.per_page,
            })
            return {
                status = 200,
                json = {
                    success = true,
                    data = result.data,
                    meta = {
                        total = result.total,
                        page = result.page,
                        per_page = result.per_page,
                        total_pages = result.total_pages,
                    }
                }
            }
        end)
    ))

    -- =========================================================================
    -- BULK IMPORT/EXPORT
    -- =========================================================================

    -- Import from .env content
    app:post("/api/v2/vault/import/env", AuthMiddleware.requireAuth(
        NamespaceMiddleware.requireNamespace(function(self)
            local vault_key = get_vault_key(self)
            if not vault_key then return api_response(401, nil, "Vault key required") end

            local data = parse_json_body()
            if not data.content then return api_response(400, nil, "content is required") end

            local parsed, err = VaultProviderQueries.parseEnvContent(data.content)
            if not parsed then return api_response(400, nil, err or "Failed to parse .env content") end

            -- Create secrets via SecretVaultQueries
            local ok_svq, SecretVaultQueries = pcall(require, "queries.SecretVaultQueries")
            if not ok_svq then return api_response(500, nil, "Vault module not available") end

            local vault = SecretVaultQueries.getVault(self.namespace.id, self.current_user.id)
            if not vault then return api_response(404, nil, "No vault found") end

            local created = 0
            local failed = 0
            local errors = {}

            for _, item in ipairs(parsed) do
                local ok_create, create_err = pcall(function()
                    SecretVaultQueries.createSecret(vault.id, vault_key, {
                        name = item.key,
                        value = item.value,
                        secret_type = "env_variable",
                        folder_id = data.folder_id,
                    }, self.current_user.id, self.namespace.id, ngx.var.remote_addr)
                end)
                if ok_create then
                    created = created + 1
                else
                    failed = failed + 1
                    errors[#errors + 1] = { key = item.key, error = tostring(create_err) }
                end
            end

            return api_response(200, {
                total = #parsed,
                created = created,
                failed = failed,
                errors = errors,
            })
        end)
    ))

    -- Export as .env
    app:get("/api/v2/vault/export/env", AuthMiddleware.requireAuth(
        NamespaceMiddleware.requireNamespace(function(self)
            local vault_key = get_vault_key(self)
            if not vault_key then return api_response(401, nil, "Vault key required") end

            local ok_svq, SecretVaultQueries = pcall(require, "queries.SecretVaultQueries")
            if not ok_svq then return api_response(500, nil, "Vault module not available") end

            local vault = SecretVaultQueries.getVault(self.namespace.id, self.current_user.id)
            if not vault then return api_response(404, nil, "No vault found") end

            local secrets = SecretVaultQueries.getSecrets(vault.id, {})
            local secrets_map = {}
            for _, s in ipairs(secrets.data or secrets) do
                local decrypted = SecretVaultQueries.readSecret(vault.id, s.id, vault_key,
                    self.current_user.id, self.namespace.id, ngx.var.remote_addr)
                if decrypted and decrypted.value then
                    secrets_map[s.name] = decrypted.value
                end
            end

            local env_content, err = VaultProviderQueries.exportAsEnv(secrets_map)
            if not env_content then return api_response(500, nil, err) end

            ngx.header["Content-Type"] = "text/plain"
            ngx.header["Content-Disposition"] = "attachment; filename=vault-export.env"
            return { status = 200, layout = false, env_content }
        end)
    ))

    -- Export as JSON
    app:get("/api/v2/vault/export/json", AuthMiddleware.requireAuth(
        NamespaceMiddleware.requireNamespace(function(self)
            local vault_key = get_vault_key(self)
            if not vault_key then return api_response(401, nil, "Vault key required") end

            local ok_svq, SecretVaultQueries = pcall(require, "queries.SecretVaultQueries")
            if not ok_svq then return api_response(500, nil, "Vault module not available") end

            local vault = SecretVaultQueries.getVault(self.namespace.id, self.current_user.id)
            if not vault then return api_response(404, nil, "No vault found") end

            local secrets = SecretVaultQueries.getSecrets(vault.id, {})
            local secrets_map = {}
            for _, s in ipairs(secrets.data or secrets) do
                local decrypted = SecretVaultQueries.readSecret(vault.id, s.id, vault_key,
                    self.current_user.id, self.namespace.id, ngx.var.remote_addr)
                if decrypted and decrypted.value then
                    secrets_map[s.name] = decrypted.value
                end
            end

            return api_response(200, secrets_map)
        end)
    ))

    -- =========================================================================
    -- SECRET ROTATION & EXPIRING
    -- =========================================================================

    -- Get expiring secrets
    app:get("/api/v2/vault/secrets/expiring", AuthMiddleware.requireAuth(
        NamespaceMiddleware.requireNamespace(function(self)
            local vault_key = get_vault_key(self)
            if not vault_key then return api_response(401, nil, "Vault key required") end

            local ok_svq, SecretVaultQueries = pcall(require, "queries.SecretVaultQueries")
            if not ok_svq then return api_response(500, nil, "Vault module not available") end

            local vault = SecretVaultQueries.getVault(self.namespace.id, self.current_user.id)
            if not vault then return api_response(404, nil, "No vault found") end

            local days = tonumber(self.params.days) or 30
            local secrets = VaultProviderQueries.getExpiringSecrets(vault.id, days)
            return api_response(200, secrets)
        end)
    ))

    -- Rotate secret (generate new random value)
    app:post("/api/v2/vault/secrets/:id/rotate", AuthMiddleware.requireAuth(
        NamespaceMiddleware.requireNamespace(function(self)
            local vault_key = get_vault_key(self)
            if not vault_key then return api_response(401, nil, "Vault key required") end

            local ok_svq, SecretVaultQueries = pcall(require, "queries.SecretVaultQueries")
            if not ok_svq then return api_response(500, nil, "Vault module not available") end

            local vault = SecretVaultQueries.getVault(self.namespace.id, self.current_user.id)
            if not vault then return api_response(404, nil, "No vault found") end

            local data = parse_json_body()
            local new_value = data.value
            if not new_value then
                -- Generate random 32-char hex string
                local handle = io.popen("openssl rand -hex 16 2>/dev/null")
                new_value = handle and handle:read("*a"):gsub("%s+", "") or Global.generateUUID():gsub("-", "")
                if handle then handle:close() end
            end

            local updated = SecretVaultQueries.updateSecret(vault.id, tonumber(self.params.id), vault_key, {
                value = new_value,
            }, self.current_user.id, self.namespace.id, ngx.var.remote_addr)

            if not updated then return api_response(500, nil, "Failed to rotate secret") end

            -- Update rotation timestamp
            db.query("UPDATE namespace_vault_secrets SET last_rotated_at = NOW() WHERE id = ? AND vault_id = ?",
                self.params.id, vault.id)

            return api_response(200, { rotated = true, secret_id = self.params.id })
        end)
    ))

    -- =========================================================================
    -- PROVIDER TYPES REFERENCE
    -- =========================================================================

    app:get("/api/v2/vault/providers/types", AuthMiddleware.requireAuth(
        NamespaceMiddleware.requireNamespace(function(self)
            return api_response(200, {
                {
                    type = "hashicorp_vault",
                    name = "HashiCorp Vault",
                    description = "Enterprise secret management with dynamic secrets and encryption as a service",
                    icon = "Shield",
                    config_fields = { "vault_url", "auth_method", "token", "role_id", "secret_id", "mount_path", "namespace" },
                },
                {
                    type = "aws_secrets_manager",
                    name = "AWS Secrets Manager",
                    description = "AWS cloud-native secrets management with automatic rotation",
                    icon = "Cloud",
                    config_fields = { "region", "access_key_id", "secret_access_key", "prefix" },
                },
                {
                    type = "azure_key_vault",
                    name = "Azure Key Vault",
                    description = "Microsoft Azure secrets, keys, and certificate management",
                    icon = "Lock",
                    config_fields = { "vault_url", "tenant_id", "client_id", "client_secret" },
                },
                {
                    type = "kubernetes",
                    name = "Kubernetes Secrets",
                    description = "Native Kubernetes secret resources in your cluster",
                    icon = "Server",
                    config_fields = { "api_server", "token", "k8s_namespace" },
                },
                {
                    type = "env_file",
                    name = ".env File Import",
                    description = "Import secrets from .env or environment variable files",
                    icon = "FileText",
                    config_fields = { "file_content" },
                },
            })
        end)
    ))

end
