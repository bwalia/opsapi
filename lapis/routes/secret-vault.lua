--[[
    Secret Vault API Routes

    Secure secret management with user-provided encryption keys.

    SECURITY MODEL:
    ===============
    - User provides a 16-character vault key for all encryption/decryption
    - The vault key is NEVER stored - user must remember it
    - Each API call that accesses secrets requires the vault key
    - All operations are scoped to the user's vault within their namespace

    AUTHENTICATION:
    ===============
    - All routes require JWT authentication (AuthMiddleware.requireAuth)
    - All routes require namespace context (NamespaceMiddleware.requireNamespace)
    - Vault ownership is verified on every operation

    ENDPOINTS:
    ==========
    Vault Management:
    - POST   /api/v2/vault                     Create vault with vault key
    - GET    /api/v2/vault                     Get vault info (no key required)
    - POST   /api/v2/vault/unlock              Unlock vault (verify key)
    - PUT    /api/v2/vault/key                 Change vault key
    - GET    /api/v2/vault/stats               Get vault statistics

    Folder Management:
    - GET    /api/v2/vault/folders             List folders
    - POST   /api/v2/vault/folders             Create folder
    - PUT    /api/v2/vault/folders/:id         Update folder
    - DELETE /api/v2/vault/folders/:id         Delete folder

    Secret Management:
    - GET    /api/v2/vault/secrets             List secrets (metadata only)
    - POST   /api/v2/vault/secrets             Create secret
    - GET    /api/v2/vault/secrets/:id         Read secret (decrypt)
    - PUT    /api/v2/vault/secrets/:id         Update secret
    - DELETE /api/v2/vault/secrets/:id         Delete secret

    Sharing:
    - POST   /api/v2/vault/secrets/:id/share   Share secret with user
    - GET    /api/v2/vault/secrets/:id/shares  Get shares for a secret
    - DELETE /api/v2/vault/shares/:id          Revoke share
    - GET    /api/v2/vault/shared              Get secrets shared with me

    Audit:
    - GET    /api/v2/vault/logs                Get access logs
]]

local cjson = require("cjson.safe")
local AuthMiddleware = require("middleware.auth")
local NamespaceMiddleware = require("middleware.namespace")
local SecretVaultQueries = require("queries.SecretVaultQueries")
local UserQueries = require("queries.UserQueries")

-- ============================================
-- Error Response Helper
-- ============================================
local function errorResponse(self, status, message, details)
    self.res.status = status
    return {
        json = {
            success = false,
            error = message,
            details = details
        }
    }
end

-- ============================================
-- Success Response Helper
-- ============================================
local function successResponse(data, message)
    local response = {
        success = true,
        data = data
    }
    if message then
        response.message = message
    end
    return { json = response }
end

-- ============================================
-- User ID Helper
-- ============================================
local function getUserId(self)
    if not self.current_user then
        return nil, "Authentication required"
    end

    -- Get user data from database using UUID
    local user_uuid = self.current_user.sub or self.current_user.uuid
    if not user_uuid then
        return nil, "User identifier not found in token"
    end

    local user_data = UserQueries.show(user_uuid)
    if not user_data then
        return nil, "User not found in database"
    end

    -- Return the internal database ID
    return user_data.internal_id or user_data.id, nil
end

-- ============================================
-- Vault Key Extraction Helper
-- ============================================
local function getVaultKey(self)
    -- Try X-Vault-Key header first
    local vault_key = self.req.headers["X-Vault-Key"] or self.req.headers["x-vault-key"]

    -- Fall back to request body
    if not vault_key and self.params.vault_key then
        vault_key = self.params.vault_key
    end

    return vault_key
end

-- ============================================
-- Route Registration
-- ============================================
return function(app)

    -- ==========================================
    -- VAULT MANAGEMENT
    -- ==========================================

    --- Create a new vault
    -- POST /api/v2/vault
    -- Body: { vault_key: string (16 chars), name?: string }
    app:post("/api/v2/vault", AuthMiddleware.requireAuth(
        NamespaceMiddleware.requireNamespace(function(self)
            local user_id, user_err = getUserId(self)
            if not user_id then
                return errorResponse(self, 401, "User not found", user_err)
            end

            local vault_key = getVaultKey(self)
            if not vault_key then
                return errorResponse(self, 400, "vault_key is required", "Provide a 16-character vault key")
            end

            local vault, err = SecretVaultQueries.createVault(
                self.namespace.id,
                user_id,
                vault_key,
                { name = self.params.name }
            )

            if not vault then
                if err:match("already exists") then
                    return errorResponse(self, 409, "Vault already exists", err)
                end
                return errorResponse(self, 400, "Failed to create vault", err)
            end

            self.res.status = 201
            return successResponse(vault, "Vault created successfully. Remember your vault key - it cannot be recovered!")
        end)
    ))

    --- Get vault info (without unlocking)
    -- GET /api/v2/vault
    app:get("/api/v2/vault", AuthMiddleware.requireAuth(
        NamespaceMiddleware.requireNamespace(function(self)
            local user_id, user_err = getUserId(self)
            if not user_id then
                return errorResponse(self, 401, "User not found", user_err)
            end

            local vault = SecretVaultQueries.getVault(self.namespace.id, user_id)

            if not vault then
                return errorResponse(self, 404, "Vault not found", "Create a vault first using POST /api/v2/vault")
            end

            return successResponse(vault)
        end)
    ))

    --- Unlock vault (verify key)
    -- POST /api/v2/vault/unlock
    -- Header: X-Vault-Key or Body: { vault_key: string }
    app:post("/api/v2/vault/unlock", AuthMiddleware.requireAuth(
        NamespaceMiddleware.requireNamespace(function(self)
            local user_id, user_err = getUserId(self)
            if not user_id then
                return errorResponse(self, 401, "User not found", user_err)
            end

            local vault = SecretVaultQueries.getVault(self.namespace.id, user_id)
            if not vault then
                return errorResponse(self, 404, "Vault not found")
            end

            local vault_key = getVaultKey(self)
            if not vault_key then
                return errorResponse(self, 400, "vault_key is required")
            end

            local result, err = SecretVaultQueries.unlockVault(vault.id, user_id, vault_key)

            if not result then
                if err:match("locked") then
                    return errorResponse(self, 423, "Vault is locked", err)
                end
                if err:match("Invalid") then
                    return errorResponse(self, 401, "Invalid vault key", err)
                end
                return errorResponse(self, 400, "Failed to unlock vault", err)
            end

            -- Don't return derived_key in response!
            return successResponse({
                vault_id = result.vault.id,
                vault_uuid = result.vault.uuid,
                status = result.vault.status,
                secrets_count = result.vault.secrets_count
            }, "Vault unlocked successfully")
        end)
    ))

    --- Change vault key
    -- PUT /api/v2/vault/key
    -- Body: { old_vault_key: string, new_vault_key: string }
    app:put("/api/v2/vault/key", AuthMiddleware.requireAuth(
        NamespaceMiddleware.requireNamespace(function(self)
            local user_id, user_err = getUserId(self)
            if not user_id then
                return errorResponse(self, 401, "User not found", user_err)
            end

            local vault = SecretVaultQueries.getVault(self.namespace.id, user_id)
            if not vault then
                return errorResponse(self, 404, "Vault not found")
            end

            if not self.params.old_vault_key then
                return errorResponse(self, 400, "old_vault_key is required")
            end

            if not self.params.new_vault_key then
                return errorResponse(self, 400, "new_vault_key is required")
            end

            local success, err = SecretVaultQueries.changeVaultKey(
                vault.id,
                user_id,
                self.params.old_vault_key,
                self.params.new_vault_key
            )

            if not success then
                return errorResponse(self, 400, "Failed to change vault key", err)
            end

            return successResponse(nil, "Vault key changed successfully. All secrets have been re-encrypted.")
        end)
    ))

    --- Get vault statistics
    -- GET /api/v2/vault/stats
    app:get("/api/v2/vault/stats", AuthMiddleware.requireAuth(
        NamespaceMiddleware.requireNamespace(function(self)
            local user_id, user_err = getUserId(self)
            if not user_id then
                return errorResponse(self, 401, "User not found", user_err)
            end

            local vault = SecretVaultQueries.getVault(self.namespace.id, user_id)
            if not vault then
                return errorResponse(self, 404, "Vault not found")
            end

            local stats = SecretVaultQueries.getVaultStats(vault.id)
            return successResponse(stats)
        end)
    ))

    -- ==========================================
    -- FOLDER MANAGEMENT
    -- ==========================================

    --- List folders
    -- GET /api/v2/vault/folders
    -- Header: X-Vault-Key required
    app:get("/api/v2/vault/folders", AuthMiddleware.requireAuth(
        NamespaceMiddleware.requireNamespace(function(self)
            local user_id, user_err = getUserId(self)
            if not user_id then
                return errorResponse(self, 401, "User not found", user_err)
            end

            local vault = SecretVaultQueries.getVault(self.namespace.id, user_id)
            if not vault then
                return errorResponse(self, 404, "Vault not found")
            end

            local vault_key = getVaultKey(self)
            if not vault_key then
                return errorResponse(self, 400, "X-Vault-Key header required")
            end

            -- Verify vault key
            local unlock_result, unlock_err = SecretVaultQueries.unlockVault(vault.id, user_id, vault_key)
            if not unlock_result then
                return errorResponse(self, 401, "Invalid vault key", unlock_err)
            end

            local folders = SecretVaultQueries.getFolders(vault.id)
            return successResponse(folders)
        end)
    ))

    --- Create folder
    -- POST /api/v2/vault/folders
    -- Header: X-Vault-Key required
    -- Body: { name: string, parent_folder_id?: number, icon?: string, color?: string, description?: string }
    app:post("/api/v2/vault/folders", AuthMiddleware.requireAuth(
        NamespaceMiddleware.requireNamespace(function(self)
            local user_id, user_err = getUserId(self)
            if not user_id then
                return errorResponse(self, 401, "User not found", user_err)
            end

            local vault = SecretVaultQueries.getVault(self.namespace.id, user_id)
            if not vault then
                return errorResponse(self, 404, "Vault not found")
            end

            local vault_key = getVaultKey(self)
            if not vault_key then
                return errorResponse(self, 400, "X-Vault-Key header required")
            end

            local unlock_result, unlock_err = SecretVaultQueries.unlockVault(vault.id, user_id, vault_key)
            if not unlock_result then
                return errorResponse(self, 401, "Invalid vault key", unlock_err)
            end

            -- Accept both parent_id and parent_folder_id for flexibility
            local parent_id = self.params.parent_folder_id or self.params.parent_id
            local folder, err = SecretVaultQueries.createFolder(vault.id, unlock_result.derived_key, {
                name = self.params.name,
                parent_folder_id = parent_id and tonumber(parent_id),
                icon = self.params.icon,
                color = self.params.color,
                description = self.params.description
            })

            if not folder then
                return errorResponse(self, 400, "Failed to create folder", err)
            end

            self.res.status = 201
            return successResponse(folder, "Folder created successfully")
        end)
    ))

    --- Update folder
    -- PUT /api/v2/vault/folders/:id
    app:put("/api/v2/vault/folders/:id", AuthMiddleware.requireAuth(
        NamespaceMiddleware.requireNamespace(function(self)
            local user_id, user_err = getUserId(self)
            if not user_id then
                return errorResponse(self, 401, "User not found", user_err)
            end

            local vault = SecretVaultQueries.getVault(self.namespace.id, user_id)
            if not vault then
                return errorResponse(self, 404, "Vault not found")
            end

            local vault_key = getVaultKey(self)
            if not vault_key then
                return errorResponse(self, 400, "X-Vault-Key header required")
            end

            local unlock_result, unlock_err = SecretVaultQueries.unlockVault(vault.id, user_id, vault_key)
            if not unlock_result then
                return errorResponse(self, 401, "Invalid vault key", unlock_err)
            end

            local folder, err = SecretVaultQueries.updateFolder(self.params.id, vault.id, {
                name = self.params.name,
                icon = self.params.icon,
                color = self.params.color,
                description = self.params.description
            })

            if not folder then
                return errorResponse(self, 404, "Folder not found", err)
            end

            return successResponse(folder, "Folder updated successfully")
        end)
    ))

    --- Delete folder
    -- DELETE /api/v2/vault/folders/:id
    app:delete("/api/v2/vault/folders/:id", AuthMiddleware.requireAuth(
        NamespaceMiddleware.requireNamespace(function(self)
            local user_id, user_err = getUserId(self)
            if not user_id then
                return errorResponse(self, 401, "User not found", user_err)
            end

            local vault = SecretVaultQueries.getVault(self.namespace.id, user_id)
            if not vault then
                return errorResponse(self, 404, "Vault not found")
            end

            local vault_key = getVaultKey(self)
            if not vault_key then
                return errorResponse(self, 400, "X-Vault-Key header required")
            end

            local unlock_result, unlock_err = SecretVaultQueries.unlockVault(vault.id, user_id, vault_key)
            if not unlock_result then
                return errorResponse(self, 401, "Invalid vault key", unlock_err)
            end

            local success, err = SecretVaultQueries.deleteFolder(self.params.id, vault.id)

            if not success then
                return errorResponse(self, 404, "Folder not found", err)
            end

            return successResponse(nil, "Folder deleted successfully")
        end)
    ))

    -- ==========================================
    -- SECRET MANAGEMENT
    -- ==========================================

    --- List secrets (metadata only, no values)
    -- GET /api/v2/vault/secrets
    -- Header: X-Vault-Key required
    -- Query: folder_id?, secret_type?, search?, page?, per_page?
    app:get("/api/v2/vault/secrets", AuthMiddleware.requireAuth(
        NamespaceMiddleware.requireNamespace(function(self)
            local user_id, user_err = getUserId(self)
            if not user_id then
                return errorResponse(self, 401, "User not found", user_err)
            end

            local vault = SecretVaultQueries.getVault(self.namespace.id, user_id)
            if not vault then
                return errorResponse(self, 404, "Vault not found")
            end

            local vault_key = getVaultKey(self)
            if not vault_key then
                return errorResponse(self, 400, "X-Vault-Key header required")
            end

            local unlock_result, unlock_err = SecretVaultQueries.unlockVault(vault.id, user_id, vault_key)
            if not unlock_result then
                return errorResponse(self, 401, "Invalid vault key", unlock_err)
            end

            local result = SecretVaultQueries.getSecrets(vault.id, {
                folder_id = self.params.folder_id and tonumber(self.params.folder_id),
                secret_type = self.params.secret_type,
                search = self.params.search,
                page = self.params.page,
                per_page = self.params.per_page or self.params.perPage
            })

            return successResponse(result)
        end)
    ))

    --- Create secret
    -- POST /api/v2/vault/secrets
    -- Header: X-Vault-Key required
    -- Body: { name, value, secret_type?, folder_id?, description?, icon?, color?, tags?, metadata?, expires_at?, rotation_reminder_at? }
    app:post("/api/v2/vault/secrets", AuthMiddleware.requireAuth(
        NamespaceMiddleware.requireNamespace(function(self)
            local user_id, user_err = getUserId(self)
            if not user_id then
                return errorResponse(self, 401, "User not found", user_err)
            end

            local vault = SecretVaultQueries.getVault(self.namespace.id, user_id)
            if not vault then
                return errorResponse(self, 404, "Vault not found")
            end

            local vault_key = getVaultKey(self)
            if not vault_key then
                return errorResponse(self, 400, "X-Vault-Key header required")
            end

            local unlock_result, unlock_err = SecretVaultQueries.unlockVault(vault.id, user_id, vault_key)
            if not unlock_result then
                return errorResponse(self, 401, "Invalid vault key", unlock_err)
            end

            local secret, err = SecretVaultQueries.createSecret(
                vault.id,
                unlock_result.derived_key,
                {
                    name = self.params.name,
                    value = self.params.value,
                    secret_type = self.params.secret_type,
                    folder_id = self.params.folder_id and tonumber(self.params.folder_id),
                    description = self.params.description,
                    icon = self.params.icon,
                    color = self.params.color,
                    tags = self.params.tags,
                    metadata = self.params.metadata,
                    expires_at = self.params.expires_at,
                    rotation_reminder_at = self.params.rotation_reminder_at
                },
                user_id
            )

            if not secret then
                return errorResponse(self, 400, "Failed to create secret", err)
            end

            self.res.status = 201
            return successResponse(secret, "Secret created and encrypted successfully")
        end)
    ))

    --- Read secret (decrypt and return value)
    -- GET /api/v2/vault/secrets/:id
    -- Header: X-Vault-Key required
    app:get("/api/v2/vault/secrets/:id", AuthMiddleware.requireAuth(
        NamespaceMiddleware.requireNamespace(function(self)
            local user_id, user_err = getUserId(self)
            if not user_id then
                return errorResponse(self, 401, "User not found", user_err)
            end

            local vault = SecretVaultQueries.getVault(self.namespace.id, user_id)
            if not vault then
                return errorResponse(self, 404, "Vault not found")
            end

            local vault_key = getVaultKey(self)
            if not vault_key then
                return errorResponse(self, 400, "X-Vault-Key header required")
            end

            local unlock_result, unlock_err = SecretVaultQueries.unlockVault(vault.id, user_id, vault_key)
            if not unlock_result then
                return errorResponse(self, 401, "Invalid vault key", unlock_err)
            end

            local secret, err = SecretVaultQueries.readSecret(
                self.params.id,
                vault.id,
                unlock_result.derived_key,
                user_id
            )

            if not secret then
                if err and err:match("not found") then
                    return errorResponse(self, 404, "Secret not found")
                end
                return errorResponse(self, 400, "Failed to read secret", err)
            end

            return successResponse(secret)
        end)
    ))

    --- Update secret
    -- PUT /api/v2/vault/secrets/:id
    -- Header: X-Vault-Key required
    app:put("/api/v2/vault/secrets/:id", AuthMiddleware.requireAuth(
        NamespaceMiddleware.requireNamespace(function(self)
            local user_id, user_err = getUserId(self)
            if not user_id then
                return errorResponse(self, 401, "User not found", user_err)
            end

            local vault = SecretVaultQueries.getVault(self.namespace.id, user_id)
            if not vault then
                return errorResponse(self, 404, "Vault not found")
            end

            local vault_key = getVaultKey(self)
            if not vault_key then
                return errorResponse(self, 400, "X-Vault-Key header required")
            end

            local unlock_result, unlock_err = SecretVaultQueries.unlockVault(vault.id, user_id, vault_key)
            if not unlock_result then
                return errorResponse(self, 401, "Invalid vault key", unlock_err)
            end

            local secret, err = SecretVaultQueries.updateSecret(
                self.params.id,
                vault.id,
                unlock_result.derived_key,
                {
                    name = self.params.name,
                    value = self.params.value,
                    secret_type = self.params.secret_type,
                    folder_id = self.params.folder_id,
                    description = self.params.description,
                    icon = self.params.icon,
                    color = self.params.color,
                    tags = self.params.tags,
                    metadata = self.params.metadata,
                    expires_at = self.params.expires_at,
                    rotation_reminder_at = self.params.rotation_reminder_at
                },
                user_id
            )

            if not secret then
                if err and err:match("not found") then
                    return errorResponse(self, 404, "Secret not found")
                end
                return errorResponse(self, 400, "Failed to update secret", err)
            end

            return successResponse(secret, "Secret updated successfully")
        end)
    ))

    --- Delete secret
    -- DELETE /api/v2/vault/secrets/:id
    -- Header: X-Vault-Key required
    app:delete("/api/v2/vault/secrets/:id", AuthMiddleware.requireAuth(
        NamespaceMiddleware.requireNamespace(function(self)
            local user_id, user_err = getUserId(self)
            if not user_id then
                return errorResponse(self, 401, "User not found", user_err)
            end

            local vault = SecretVaultQueries.getVault(self.namespace.id, user_id)
            if not vault then
                return errorResponse(self, 404, "Vault not found")
            end

            local vault_key = getVaultKey(self)
            if not vault_key then
                return errorResponse(self, 400, "X-Vault-Key header required")
            end

            local unlock_result, unlock_err = SecretVaultQueries.unlockVault(vault.id, user_id, vault_key)
            if not unlock_result then
                return errorResponse(self, 401, "Invalid vault key", unlock_err)
            end

            local success, err = SecretVaultQueries.deleteSecret(
                self.params.id,
                vault.id,
                user_id
            )

            if not success then
                if err and err:match("not found") then
                    return errorResponse(self, 404, "Secret not found")
                end
                return errorResponse(self, 400, "Failed to delete secret", err)
            end

            return successResponse(nil, "Secret deleted successfully")
        end)
    ))

    -- ==========================================
    -- SHARING
    -- ==========================================

    --- Share a secret with another user
    -- POST /api/v2/vault/secrets/:id/share
    -- Header: X-Vault-Key required
    -- Body: { target_user_id, target_vault_key, permission?, can_reshare?, expires_at?, message? }
    app:post("/api/v2/vault/secrets/:id/share", AuthMiddleware.requireAuth(
        NamespaceMiddleware.requireNamespace(function(self)
            local user_id, user_err = getUserId(self)
            if not user_id then
                return errorResponse(self, 401, "User not found", user_err)
            end

            local vault = SecretVaultQueries.getVault(self.namespace.id, user_id)
            if not vault then
                return errorResponse(self, 404, "Vault not found")
            end

            local vault_key = getVaultKey(self)
            if not vault_key then
                return errorResponse(self, 400, "X-Vault-Key header required")
            end

            local unlock_result, unlock_err = SecretVaultQueries.unlockVault(vault.id, user_id, vault_key)
            if not unlock_result then
                return errorResponse(self, 401, "Invalid vault key", unlock_err)
            end

            if not self.params.target_user_id then
                return errorResponse(self, 400, "target_user_id is required")
            end

            if not self.params.target_vault_key then
                return errorResponse(self, 400, "target_vault_key is required", "The target user must provide their vault key")
            end

            local share, err = SecretVaultQueries.shareSecret(
                self.params.id,
                vault.id,
                unlock_result.derived_key,
                tonumber(self.params.target_user_id),
                self.params.target_vault_key,
                {
                    permission = self.params.permission,
                    can_reshare = self.params.can_reshare,
                    expires_at = self.params.expires_at,
                    message = self.params.message
                },
                user_id
            )

            if not share then
                return errorResponse(self, 400, "Failed to share secret", err)
            end

            self.res.status = 201
            return successResponse(share, "Secret shared successfully")
        end)
    ))

    --- Get shares for a secret
    -- GET /api/v2/vault/secrets/:id/shares
    app:get("/api/v2/vault/secrets/:id/shares", AuthMiddleware.requireAuth(
        NamespaceMiddleware.requireNamespace(function(self)
            local user_id, user_err = getUserId(self)
            if not user_id then
                return errorResponse(self, 401, "User not found", user_err)
            end

            local vault = SecretVaultQueries.getVault(self.namespace.id, user_id)
            if not vault then
                return errorResponse(self, 404, "Vault not found")
            end

            local shares = SecretVaultQueries.getSecretShares(self.params.id, vault.id)
            return successResponse(shares)
        end)
    ))

    --- Revoke a share
    -- DELETE /api/v2/vault/shares/:id
    app:delete("/api/v2/vault/shares/:id", AuthMiddleware.requireAuth(
        NamespaceMiddleware.requireNamespace(function(self)
            local user_id, user_err = getUserId(self)
            if not user_id then
                return errorResponse(self, 401, "User not found", user_err)
            end

            local success, err = SecretVaultQueries.revokeShare(
                self.params.id,
                user_id
            )

            if not success then
                if err and err:match("not found") then
                    return errorResponse(self, 404, "Share not found")
                end
                return errorResponse(self, 400, "Failed to revoke share", err)
            end

            return successResponse(nil, "Share revoked successfully")
        end)
    ))

    --- Get secrets shared with me
    -- GET /api/v2/vault/shared
    app:get("/api/v2/vault/shared", AuthMiddleware.requireAuth(
        NamespaceMiddleware.requireNamespace(function(self)
            local user_id, user_err = getUserId(self)
            if not user_id then
                return errorResponse(self, 401, "User not found", user_err)
            end

            local vault = SecretVaultQueries.getVault(self.namespace.id, user_id)
            if not vault then
                return errorResponse(self, 404, "Vault not found")
            end

            local shared = SecretVaultQueries.getSharedWithMe(vault.id)
            return successResponse(shared)
        end)
    ))

    -- ==========================================
    -- AUDIT LOGS
    -- ==========================================

    --- Get access logs
    -- GET /api/v2/vault/logs
    -- Query: page?, per_page?, action?, start_date?, end_date?
    app:get("/api/v2/vault/logs", AuthMiddleware.requireAuth(
        NamespaceMiddleware.requireNamespace(function(self)
            local user_id, user_err = getUserId(self)
            if not user_id then
                return errorResponse(self, 401, "User not found", user_err)
            end

            local vault = SecretVaultQueries.getVault(self.namespace.id, user_id)
            if not vault then
                return errorResponse(self, 404, "Vault not found")
            end

            local logs = SecretVaultQueries.getAccessLogs(vault.id, {
                page = self.params.page,
                per_page = self.params.per_page or self.params.perPage,
                action = self.params.action,
                start_date = self.params.start_date,
                end_date = self.params.end_date
            })

            return successResponse(logs)
        end)
    ))

    -- ==========================================
    -- USER SEARCH FOR SHARING
    -- ==========================================

    --- Search users in namespace for sharing
    -- GET /api/v2/vault/users/search
    -- Query: q (search query), limit? (default 10)
    app:get("/api/v2/vault/users/search", AuthMiddleware.requireAuth(
        NamespaceMiddleware.requireNamespace(function(self)
            local user_id, user_err = getUserId(self)
            if not user_id then
                return errorResponse(self, 401, "User not found", user_err)
            end

            local search_query = self.params.q or ""
            local limit = tonumber(self.params.limit) or 10

            -- Search users in the same namespace (excluding current user)
            local users = SecretVaultQueries.searchNamespaceUsers(
                self.namespace.id,
                user_id,
                search_query,
                limit
            )

            return successResponse(users)
        end)
    ))

end
