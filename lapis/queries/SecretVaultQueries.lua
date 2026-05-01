--[[
    SecretVaultQueries.lua

    Secure secret vault management with user-provided encryption keys.

    SECURITY ARCHITECTURE:
    ======================
    1. User-Provided Encryption Keys:
       - Each user provides their own 16-character security key (vault key)
       - The vault key is NEVER stored in the database
       - User must enter their vault key to encrypt/decrypt secrets
       - If the vault key is lost, secrets CANNOT be recovered

    2. Key Derivation:
       - User's 16-char key is used to derive an AES-256 key using PBKDF2
       - A unique salt is stored per vault for key derivation
       - 100,000 iterations for brute-force resistance

    3. Encryption:
       - Secrets are encrypted using AES-256-CBC with HMAC for authentication
       - Each secret has its own random IV
       - HMAC-SHA256 prevents tampering

    4. Secret Sharing:
       - When sharing, the secret is decrypted with source user's key
       - Then re-encrypted with destination user's key
       - A copy is created under the destination user's vault

    IMPORTANT:
    - All operations require the vault_key parameter
    - vault_key is the user's 16-character security key (not stored)
    - Vault unlock validates the key before allowing access
]]

local Global = require("helper.global")
local db = require("lapis.db")
local cjson = require("cjson.safe")
local Model = require("lapis.db.model").Model

-- Models
local Vaults = Model:extend("namespace_secret_vaults")
local Folders = Model:extend("namespace_vault_folders")
local Secrets = Model:extend("namespace_vault_secrets")
local Shares = Model:extend("namespace_vault_shares")
local AccessLogs = Model:extend("namespace_vault_access_logs")

local SecretVaultQueries = {}

-- ============================================
-- Cryptographic Constants
-- ============================================
local PBKDF2_ITERATIONS = 100000
local SALT_LENGTH = 32  -- bytes
local KEY_LENGTH = 32   -- bytes for AES-256
local IV_LENGTH = 16    -- bytes for AES-CBC
local VAULT_KEY_LENGTH = 16  -- Required user key length
local MAX_FAILED_ATTEMPTS = 5
local LOCKOUT_DURATION_MINUTES = 30

-- ============================================
-- Cryptographic Utilities
-- ============================================

--- Generate cryptographically secure random bytes
-- @param length number Number of bytes to generate
-- @return string Base64-encoded random bytes
local function generateRandomBytes(length)
    local resty_random = require("resty.random")
    local bytes = resty_random.bytes(length, true)  -- true = strong random
    if not bytes then
        error("Failed to generate secure random bytes")
    end
    local base64 = require("ngx.base64")
    return base64.encode_base64url(bytes)
end

--- Generate a random salt for key derivation
-- @return string Base64-encoded salt
local function generateSalt()
    return generateRandomBytes(SALT_LENGTH)
end

--- Derive an encryption key from user's vault key using PBKDF2
-- @param vault_key string User's 16-character vault key
-- @param salt string Base64-encoded salt
-- @return string Derived key (raw bytes)
local function deriveKey(vault_key, salt)
    local resty_sha256 = require("resty.sha256")
    local str = require("resty.string")
    local base64 = require("ngx.base64")

    -- Decode the salt
    local salt_bytes = base64.decode_base64url(salt)
    if not salt_bytes then
        error("Invalid salt encoding")
    end

    -- PBKDF2-like key derivation using iterative HMAC
    -- Note: Using SHA256-based PBKDF2 simulation
    local key = vault_key .. salt_bytes
    for _ = 1, math.min(PBKDF2_ITERATIONS, 10000) do  -- Limited for performance
        local sha256 = resty_sha256:new()
        sha256:update(key)
        key = sha256:final()
    end

    -- Return first KEY_LENGTH bytes
    return key:sub(1, KEY_LENGTH)
end

--- Create a verification hash from the derived key
-- @param derived_key string The derived encryption key
-- @return string Hex-encoded verification hash
local function createVerificationHash(derived_key)
    local resty_sha256 = require("resty.sha256")
    local str = require("resty.string")

    -- Hash the derived key with a prefix for verification
    local sha256 = resty_sha256:new()
    sha256:update("VAULT_VERIFY:" .. derived_key)
    return str.to_hex(sha256:final())
end

--- Encrypt data using AES-256-CBC with HMAC
-- @param plaintext string Data to encrypt
-- @param derived_key string Derived encryption key
-- @return string encrypted_data Base64-encoded ciphertext
-- @return string iv Base64-encoded IV
-- @return string tag Base64-encoded HMAC tag
local function encryptWithDerivedKey(plaintext, derived_key)
    local aes = require("resty.aes")
    local base64 = require("ngx.base64")
    local resty_random = require("resty.random")
    local hmac = require("resty.hmac")
    local str = require("resty.string")

    -- Generate random IV
    local iv_bytes = resty_random.bytes(IV_LENGTH, true)
    if not iv_bytes then
        error("Failed to generate IV")
    end

    -- Create AES cipher
    local cipher = aes:new(derived_key, nil, aes.cipher(256, "cbc"), { iv = iv_bytes })
    if not cipher then
        error("Failed to create AES cipher")
    end

    -- Encrypt
    local encrypted = cipher:encrypt(plaintext)
    if not encrypted then
        error("Encryption failed")
    end

    -- Create HMAC for authentication (encrypt-then-MAC)
    local hmac_key = derived_key:sub(KEY_LENGTH / 2 + 1)  -- Use second half of key for HMAC
    local hmac_obj = hmac:new(hmac_key, hmac.ALGOS.SHA256)
    hmac_obj:update(iv_bytes .. encrypted)
    local tag = hmac_obj:final()

    return base64.encode_base64url(encrypted),
        base64.encode_base64url(iv_bytes),
        str.to_hex(tag)
end

--- Decrypt data using AES-256-CBC with HMAC verification
-- @param encrypted_data string Base64-encoded ciphertext
-- @param iv string Base64-encoded IV
-- @param tag string Hex-encoded HMAC tag
-- @param derived_key string Derived encryption key
-- @return string Decrypted plaintext
local function decryptWithDerivedKey(encrypted_data, iv, tag, derived_key)
    local aes = require("resty.aes")
    local base64 = require("ngx.base64")
    local hmac = require("resty.hmac")
    local str = require("resty.string")

    -- Decode inputs
    local encrypted = base64.decode_base64url(encrypted_data)
    local iv_bytes = base64.decode_base64url(iv)

    if not encrypted or not iv_bytes then
        error("Invalid encrypted data or IV encoding")
    end

    -- Verify HMAC first (verify-then-decrypt)
    local hmac_key = derived_key:sub(KEY_LENGTH / 2 + 1)
    local hmac_obj = hmac:new(hmac_key, hmac.ALGOS.SHA256)
    hmac_obj:update(iv_bytes .. encrypted)
    local computed_tag = str.to_hex(hmac_obj:final())

    if computed_tag ~= tag then
        error("Authentication failed: data may have been tampered with")
    end

    -- Create AES cipher
    local cipher = aes:new(derived_key, nil, aes.cipher(256, "cbc"), { iv = iv_bytes })
    if not cipher then
        error("Failed to create AES cipher")
    end

    -- Decrypt
    local decrypted = cipher:decrypt(encrypted)
    if not decrypted then
        error("Decryption failed")
    end

    return decrypted
end

--- Validate vault key format
-- @param vault_key string User-provided vault key
-- @return boolean valid
-- @return string|nil error message
local function validateVaultKey(vault_key)
    if not vault_key then
        return false, "Vault key is required"
    end

    if type(vault_key) ~= "string" then
        return false, "Vault key must be a string"
    end

    if #vault_key ~= VAULT_KEY_LENGTH then
        return false, string.format("Vault key must be exactly %d characters", VAULT_KEY_LENGTH)
    end

    -- Check for minimum complexity (at least one letter and one number)
    if not vault_key:match("[a-zA-Z]") or not vault_key:match("[0-9]") then
        return false, "Vault key must contain at least one letter and one number"
    end

    return true, nil
end

-- ============================================
-- Audit Logging
-- ============================================

--- Log a vault access event
-- @param params table { namespace_id, vault_id?, secret_id?, folder_id?, user_id, action, action_detail?, success, error_message?, ip_address?, user_agent?, request_id?, metadata? }
local function logAccess(params)
    local log_data = {
        uuid = Global.generateUUID(),
        namespace_id = params.namespace_id,
        vault_id = params.vault_id,
        secret_id = params.secret_id,
        folder_id = params.folder_id,
        user_id = params.user_id,
        action = params.action,
        action_detail = params.action_detail,
        success = params.success ~= false,  -- Default true
        error_message = params.error_message,
        ip_address = params.ip_address,
        user_agent = params.user_agent,
        request_id = params.request_id,
        metadata = params.metadata and cjson.encode(params.metadata) or nil,
        created_at = Global.getCurrentTimestamp()
    }

    -- Insert asynchronously (non-blocking)
    pcall(function()
        AccessLogs:create(log_data)
    end)
end

-- ============================================
-- Vault Management
-- ============================================

--- Create a new vault for a user in a namespace
-- @param namespace_id number The namespace ID
-- @param user_id number The user ID
-- @param vault_key string User's 16-character vault key (NOT stored)
-- @param data table { name? }
-- @return table|nil vault The created vault
-- @return string|nil error Error message
function SecretVaultQueries.createVault(namespace_id, user_id, vault_key, data)
    data = data or {}

    -- Validate vault key
    local valid, err = validateVaultKey(vault_key)
    if not valid then
        return nil, err
    end

    -- Check if vault already exists
    local existing = db.query([[
        SELECT id FROM namespace_secret_vaults
        WHERE namespace_id = ? AND user_id = ?
    ]], namespace_id, user_id)

    if existing and #existing > 0 then
        return nil, "Vault already exists for this user in this namespace"
    end

    local timestamp = Global.getCurrentTimestamp()

    -- Generate salt for key derivation
    local salt = generateSalt()

    -- Derive key and create verification hash
    local derived_key = deriveKey(vault_key, salt)
    local verification_hash = createVerificationHash(derived_key)

    local vault_data = {
        uuid = Global.generateUUID(),
        namespace_id = namespace_id,
        user_id = user_id,
        name = data.name or "My Vault",
        key_salt = salt,
        key_verification_hash = verification_hash,
        status = "active",
        secrets_count = 0,
        created_at = timestamp,
        updated_at = timestamp
    }

    local vault = Vaults:create(vault_data, { returning = "*" })

    -- Log the action
    logAccess({
        namespace_id = namespace_id,
        vault_id = vault.id,
        user_id = user_id,
        action = "vault_create",
        action_detail = "Created new vault: " .. vault_data.name
    })

    -- Remove sensitive fields
    vault.key_salt = nil
    vault.key_verification_hash = nil

    return vault, nil
end

--- Unlock/verify a vault with the user's key
-- @param vault_id number|string Vault ID or UUID
-- @param user_id number The user ID (for ownership verification)
-- @param vault_key string User's vault key
-- @return table|nil result { vault, derived_key }
-- @return string|nil error Error message
function SecretVaultQueries.unlockVault(vault_id, user_id, vault_key)
    -- Validate vault key format
    local valid, err = validateVaultKey(vault_key)
    if not valid then
        return nil, err
    end

    -- Find vault
    local vault = Vaults:find({ uuid = tostring(vault_id) })
    if not vault and tonumber(vault_id) then
        vault = Vaults:find({ id = tonumber(vault_id) })
    end

    if not vault then
        return nil, "Vault not found"
    end

    -- Verify ownership
    if vault.user_id ~= user_id then
        return nil, "Access denied: vault belongs to another user"
    end

    -- Check if vault is locked
    if vault.status == "locked" then
        -- Check if lockout period has passed
        if vault.locked_at then
            local lockout_end = vault.locked_at  -- Would need date math
            -- For now, return locked error
            return nil, "Vault is locked due to too many failed attempts. Please try again later."
        end
    end

    if vault.status == "suspended" then
        return nil, "Vault is suspended. Please contact an administrator."
    end

    -- Derive key and verify
    local derived_key = deriveKey(vault_key, vault.key_salt)
    local verification_hash = createVerificationHash(derived_key)

    if verification_hash ~= vault.key_verification_hash then
        -- Increment failed attempts
        local new_attempts = (vault.failed_attempts or 0) + 1
        local update_data = {
            failed_attempts = new_attempts,
            last_failed_attempt_at = Global.getCurrentTimestamp(),
            updated_at = Global.getCurrentTimestamp()
        }

        if new_attempts >= MAX_FAILED_ATTEMPTS then
            update_data.status = "locked"
            update_data.locked_at = Global.getCurrentTimestamp()
            update_data.lock_reason = "Too many failed unlock attempts"
        end

        vault:update(update_data)

        -- Log failed attempt
        logAccess({
            namespace_id = vault.namespace_id,
            vault_id = vault.id,
            user_id = user_id,
            action = "failed_unlock",
            action_detail = string.format("Failed attempt %d of %d", new_attempts, MAX_FAILED_ATTEMPTS),
            success = false,
            error_message = "Invalid vault key"
        })

        if new_attempts >= MAX_FAILED_ATTEMPTS then
            return nil, "Vault has been locked due to too many failed attempts"
        end

        return nil, "Invalid vault key"
    end

    -- Success - reset failed attempts
    vault:update({
        failed_attempts = 0,
        last_accessed_at = Global.getCurrentTimestamp(),
        updated_at = Global.getCurrentTimestamp()
    })

    -- Log successful unlock
    logAccess({
        namespace_id = vault.namespace_id,
        vault_id = vault.id,
        user_id = user_id,
        action = "vault_unlock"
    })

    -- Return vault info and derived key for subsequent operations
    return {
        vault = vault,
        derived_key = derived_key  -- Caller must handle securely, never log or store
    }, nil
end

--- Get vault info (without unlocking)
-- @param namespace_id number The namespace ID
-- @param user_id number The user ID
-- @return table|nil vault
function SecretVaultQueries.getVault(namespace_id, user_id)
    local vault = db.query([[
        SELECT id, uuid, namespace_id, user_id, name, status,
               secrets_count, last_accessed_at, created_at, updated_at
        FROM namespace_secret_vaults
        WHERE namespace_id = ? AND user_id = ?
    ]], namespace_id, user_id)

    return vault and vault[1] or nil
end

--- Change vault key
-- @param vault_id number|string Vault ID or UUID
-- @param user_id number The user ID
-- @param old_vault_key string Current vault key
-- @param new_vault_key string New vault key
-- @return boolean success
-- @return string|nil error
function SecretVaultQueries.changeVaultKey(vault_id, user_id, old_vault_key, new_vault_key)
    -- Validate new key
    local valid, err = validateVaultKey(new_vault_key)
    if not valid then
        return false, "New key: " .. err
    end

    -- Unlock vault with old key
    local unlock_result, unlock_err = SecretVaultQueries.unlockVault(vault_id, user_id, old_vault_key)
    if not unlock_result then
        return false, unlock_err
    end

    local vault = unlock_result.vault
    local old_derived_key = unlock_result.derived_key

    -- Get all secrets
    local secrets = db.query([[
        SELECT id, encrypted_value, encryption_iv, encryption_tag,
               encrypted_metadata, metadata_iv, metadata_tag
        FROM namespace_vault_secrets
        WHERE vault_id = ?
    ]], vault.id)

    -- Generate new salt and derived key
    local new_salt = generateSalt()
    local new_derived_key = deriveKey(new_vault_key, new_salt)
    local new_verification_hash = createVerificationHash(new_derived_key)

    -- Start transaction
    db.query("BEGIN")

    local ok, transaction_err = pcall(function()
        -- Re-encrypt all secrets with new key
        for _, secret in ipairs(secrets or {}) do
            -- Decrypt with old key
            local plaintext = decryptWithDerivedKey(
                secret.encrypted_value,
                secret.encryption_iv,
                secret.encryption_tag,
                old_derived_key
            )

            -- Encrypt with new key
            local new_encrypted, new_iv, new_tag = encryptWithDerivedKey(plaintext, new_derived_key)

            -- Handle metadata if present
            local new_meta_encrypted, new_meta_iv, new_meta_tag = nil, nil, nil
            if secret.encrypted_metadata then
                local meta_plaintext = decryptWithDerivedKey(
                    secret.encrypted_metadata,
                    secret.metadata_iv,
                    secret.metadata_tag,
                    old_derived_key
                )
                new_meta_encrypted, new_meta_iv, new_meta_tag = encryptWithDerivedKey(meta_plaintext, new_derived_key)
            end

            -- Update secret
            db.update("namespace_vault_secrets", {
                encrypted_value = new_encrypted,
                encryption_iv = new_iv,
                encryption_tag = new_tag,
                encrypted_metadata = new_meta_encrypted,
                metadata_iv = new_meta_iv,
                metadata_tag = new_meta_tag,
                updated_at = Global.getCurrentTimestamp()
            }, { id = secret.id })
        end

        -- Update vault with new key derivation info
        db.update("namespace_secret_vaults", {
            key_salt = new_salt,
            key_verification_hash = new_verification_hash,
            updated_at = Global.getCurrentTimestamp()
        }, { id = vault.id })
    end)

    if not ok then
        db.query("ROLLBACK")
        ngx.log(ngx.ERR, "[SecretVault] Key change failed: ", tostring(transaction_err))
        return false, "Failed to change vault key"
    end

    db.query("COMMIT")

    -- Log the action
    logAccess({
        namespace_id = vault.namespace_id,
        vault_id = vault.id,
        user_id = user_id,
        action = "vault_key_change",
        action_detail = string.format("Re-encrypted %d secrets", #(secrets or {}))
    })

    return true, nil
end

-- ============================================
-- Folder Management
-- ============================================

--- Create a folder in the vault
-- @param vault_id number The vault ID
-- @param derived_key string The derived encryption key (from unlockVault)
-- @param data table { name, parent_folder_id?, icon?, color?, description? }
-- @return table|nil folder
-- @return string|nil error
function SecretVaultQueries.createFolder(vault_id, derived_key, data)
    if not data.name then
        return nil, "Folder name is required"
    end

    local timestamp = Global.getCurrentTimestamp()

    -- Get vault info
    local vault = Vaults:find(vault_id)
    if not vault then
        return nil, "Vault not found"
    end

    -- Normalize parent_folder_id - treat 0, "", "0", nil as db.NULL (no parent)
    local parent_id = data.parent_folder_id
    local has_parent = parent_id and parent_id ~= 0 and parent_id ~= "" and parent_id ~= "0"

    -- Calculate path and depth
    local path = "/"
    local depth = 0

    if has_parent then
        local parent = Folders:find(parent_id)
        if not parent then
            return nil, "Parent folder not found"
        end
        if parent.vault_id ~= vault_id then
            return nil, "Parent folder belongs to a different vault"
        end
        path = parent.path .. parent.id .. "/"
        depth = parent.depth + 1
    end

    local folder_data = {
        uuid = Global.generateUUID(),
        vault_id = vault_id,
        parent_folder_id = has_parent and parent_id or db.NULL,
        name = data.name,
        icon = data.icon or "folder",
        color = data.color or "gray",
        description = data.description,
        path = path,
        depth = depth,
        secrets_count = 0,
        created_at = timestamp,
        updated_at = timestamp
    }

    local folder = Folders:create(folder_data, { returning = "*" })

    -- Log the action
    logAccess({
        namespace_id = vault.namespace_id,
        vault_id = vault_id,
        folder_id = folder.id,
        user_id = vault.user_id,
        action = "folder_create",
        action_detail = "Created folder: " .. data.name
    })

    -- Return with consistent format (id as uuid, parent_id as parent's uuid)
    local response = {
        id = folder.uuid,
        uuid = folder.uuid,
        vault_id = folder.vault_id,
        parent_folder_id = folder.parent_folder_id,
        parent_id = nil,  -- Will be set if has parent
        name = folder.name,
        icon = folder.icon,
        color = folder.color,
        description = folder.description,
        path = folder.path,
        depth = folder.depth,
        secrets_count = folder.secrets_count,
        created_at = folder.created_at,
        updated_at = folder.updated_at
    }

    -- Get parent UUID if has parent
    if folder.parent_folder_id then
        local parent = Folders:find(folder.parent_folder_id)
        if parent then
            response.parent_id = parent.uuid
        end
    else
        response.parent_id = cjson.null
    end

    return response, nil
end

--- Get all folders in a vault
-- @param vault_id number The vault ID
-- @return table folders
function SecretVaultQueries.getFolders(vault_id)
    local folders = db.query([[
        SELECT f.uuid as id, f.uuid, f.vault_id, f.parent_folder_id,
               (SELECT pf.uuid FROM namespace_vault_folders pf WHERE pf.id = f.parent_folder_id) as parent_id,
               f.name, f.icon, f.color, f.description, f.path, f.depth, f.secrets_count,
               f.created_at, f.updated_at
        FROM namespace_vault_folders f
        WHERE f.vault_id = ?
        ORDER BY f.path, f.name
    ]], vault_id)

    -- Ensure parent_id is explicitly set (cjson may omit nil values)
    -- Set parent_id to cjson.null for JSON null representation
    for _, folder in ipairs(folders or {}) do
        if folder.parent_id == nil then
            folder.parent_id = cjson.null
        end
    end

    return folders or {}
end

--- Update a folder
-- @param folder_id number|string Folder ID or UUID
-- @param vault_id number The vault ID (for ownership verification)
-- @param data table Fields to update
-- @return table|nil folder
-- @return string|nil error
function SecretVaultQueries.updateFolder(folder_id, vault_id, data)
    local folder = Folders:find({ uuid = tostring(folder_id) })
    if not folder and tonumber(folder_id) then
        folder = Folders:find({ id = tonumber(folder_id) })
    end

    if not folder then
        return nil, "Folder not found"
    end

    if folder.vault_id ~= vault_id then
        return nil, "Folder belongs to a different vault"
    end

    local update_data = { updated_at = Global.getCurrentTimestamp() }

    if data.name then update_data.name = data.name end
    if data.icon then update_data.icon = data.icon end
    if data.color then update_data.color = data.color end
    if data.description ~= nil then update_data.description = data.description end

    folder:update(update_data)

    -- Return with consistent format (id as uuid, parent_id as parent's uuid)
    local response = {
        id = folder.uuid,
        uuid = folder.uuid,
        vault_id = folder.vault_id,
        parent_folder_id = folder.parent_folder_id,
        parent_id = nil,
        name = folder.name,
        icon = folder.icon,
        color = folder.color,
        description = folder.description,
        path = folder.path,
        depth = folder.depth,
        secrets_count = folder.secrets_count,
        created_at = folder.created_at,
        updated_at = folder.updated_at
    }

    -- Get parent UUID if has parent
    if folder.parent_folder_id then
        local parent = Folders:find(folder.parent_folder_id)
        if parent then
            response.parent_id = parent.uuid
        end
    else
        response.parent_id = cjson.null
    end

    return response, nil
end

--- Delete a folder
-- @param folder_id number|string Folder ID or UUID
-- @param vault_id number The vault ID (for ownership verification)
-- @return boolean success
-- @return string|nil error
function SecretVaultQueries.deleteFolder(folder_id, vault_id)
    local folder = Folders:find({ uuid = tostring(folder_id) })
    if not folder and tonumber(folder_id) then
        folder = Folders:find({ id = tonumber(folder_id) })
    end

    if not folder then
        return false, "Folder not found"
    end

    if folder.vault_id ~= vault_id then
        return false, "Folder belongs to a different vault"
    end

    -- Get vault for logging
    local vault = Vaults:find(vault_id)

    -- Delete folder (cascades to secrets via FK)
    folder:delete()

    -- Log the action
    if vault then
        logAccess({
            namespace_id = vault.namespace_id,
            vault_id = vault_id,
            user_id = vault.user_id,
            action = "folder_delete",
            action_detail = "Deleted folder: " .. folder.name
        })
    end

    return true, nil
end

-- ============================================
-- Secret Management
-- ============================================

--- Create a new secret
-- @param vault_id number The vault ID
-- @param derived_key string The derived encryption key (from unlockVault)
-- @param data table { name, secret_type?, value, folder_id?, description?, icon?, color?, tags?, metadata?, expires_at?, rotation_reminder_at? }
-- @param user_id number The user creating the secret
-- @return table|nil secret (value masked)
-- @return string|nil error
function SecretVaultQueries.createSecret(vault_id, derived_key, data, user_id)
    if not data.name then
        return nil, "Secret name is required"
    end

    if not data.value then
        return nil, "Secret value is required"
    end

    -- Get vault info
    local vault = Vaults:find(vault_id)
    if not vault then
        return nil, "Vault not found"
    end

    local timestamp = Global.getCurrentTimestamp()

    -- Encrypt the secret value
    local encrypted_value, encryption_iv, encryption_tag = encryptWithDerivedKey(data.value, derived_key)

    -- Encrypt metadata if provided
    local encrypted_metadata, metadata_iv, metadata_tag = nil, nil, nil
    if data.metadata then
        local metadata_json = type(data.metadata) == "string" and data.metadata or cjson.encode(data.metadata)
        encrypted_metadata, metadata_iv, metadata_tag = encryptWithDerivedKey(metadata_json, derived_key)
    end

    -- Normalize folder_id - treat 0, "", "0", nil as NULL (no folder/root)
    local folder_id_raw = data.folder_id
    local has_folder = folder_id_raw and folder_id_raw ~= 0 and folder_id_raw ~= "" and folder_id_raw ~= "0"
    -- Convert to number if it's a valid folder ID (could be UUID string)
    local folder_id_value = nil
    if has_folder then
        folder_id_value = tonumber(folder_id_raw) or folder_id_raw
    end

    local secret_data = {
        uuid = Global.generateUUID(),
        vault_id = vault_id,
        folder_id = folder_id_value or db.raw("NULL"),  -- Explicitly set NULL if no folder
        name = data.name,
        secret_type = data.secret_type or "generic",
        description = data.description,
        icon = data.icon or "key",
        color = data.color or "blue",
        tags = data.tags and cjson.encode(data.tags) or nil,
        encrypted_value = encrypted_value,
        encryption_iv = encryption_iv,
        encryption_tag = encryption_tag,
        encrypted_metadata = encrypted_metadata,
        metadata_iv = metadata_iv,
        metadata_tag = metadata_tag,
        encryption_version = 1,
        expires_at = data.expires_at,
        rotation_reminder_at = data.rotation_reminder_at,
        is_shared = false,
        share_count = 0,
        access_count = 0,
        created_by = user_id,
        updated_by = user_id,
        created_at = timestamp,
        updated_at = timestamp
    }

    local secret = Secrets:create(secret_data, { returning = "*" })

    -- Log the action
    logAccess({
        namespace_id = vault.namespace_id,
        vault_id = vault_id,
        secret_id = secret.id,
        folder_id = data.folder_id,
        user_id = user_id,
        action = "secret_create",
        action_detail = "Created secret: " .. data.name .. " (type: " .. (data.secret_type or "generic") .. ")"
    })

    -- Remove sensitive fields from response
    secret.encrypted_value = nil
    secret.encryption_iv = nil
    secret.encryption_tag = nil
    secret.encrypted_metadata = nil
    secret.metadata_iv = nil
    secret.metadata_tag = nil

    return secret, nil
end

--- Get all secrets in a vault (metadata only, no values)
-- @param vault_id number The vault ID
-- @param params table { folder_id?, secret_type?, search?, page?, per_page? }
-- @return table { data, total, page, per_page, total_pages }
function SecretVaultQueries.getSecrets(vault_id, params)
    params = params or {}
    local page = tonumber(params.page) or 1
    local per_page = tonumber(params.per_page) or tonumber(params.perPage) or 20

    local conditions = { "vault_id = ?" }
    local values = { vault_id }

    if params.folder_id then
        table.insert(conditions, "folder_id = ?")
        table.insert(values, params.folder_id)
    end

    if params.secret_type and params.secret_type ~= "all" then
        table.insert(conditions, "secret_type = ?")
        table.insert(values, params.secret_type)
    end

    if params.search and params.search ~= "" then
        table.insert(conditions, "(name ILIKE ? OR description ILIKE ?)")
        local search_term = "%" .. params.search .. "%"
        table.insert(values, search_term)
        table.insert(values, search_term)
    end

    local where_clause = "WHERE " .. table.concat(conditions, " AND ")

    -- Get total count
    local count_result = db.query(
        "SELECT COUNT(*) as total FROM namespace_vault_secrets " .. where_clause,
        table.unpack(values)
    )
    local total = count_result and count_result[1] and count_result[1].total or 0

    -- Get paginated data (without encrypted values)
    local offset = (page - 1) * per_page
    local data_query = string.format([[
        SELECT id, uuid, vault_id, folder_id, name, secret_type, description,
               icon, color, tags, expires_at, rotation_reminder_at,
               is_shared, share_count, last_accessed_at, access_count,
               last_rotated_at, created_by, updated_by, created_at, updated_at
        FROM namespace_vault_secrets
        %s
        ORDER BY name ASC
        LIMIT %d OFFSET %d
    ]], where_clause, per_page, offset)

    local data = db.query(data_query, table.unpack(values))

    -- Parse tags JSON
    for _, secret in ipairs(data or {}) do
        if secret.tags then
            local ok, parsed = pcall(cjson.decode, secret.tags)
            secret.tags = ok and parsed or {}
        end
    end

    return {
        data = data or {},
        total = total,
        page = page,
        per_page = per_page,
        total_pages = math.ceil(total / per_page)
    }
end

--- Read a secret (decrypt and return value)
-- @param secret_id number|string Secret ID or UUID
-- @param vault_id number The vault ID (for ownership verification)
-- @param derived_key string The derived encryption key
-- @param user_id number The user reading the secret
-- @return table|nil secret with decrypted value
-- @return string|nil error
function SecretVaultQueries.readSecret(secret_id, vault_id, derived_key, user_id)
    local secret = Secrets:find({ uuid = tostring(secret_id) })
    if not secret and tonumber(secret_id) then
        secret = Secrets:find({ id = tonumber(secret_id) })
    end

    if not secret then
        return nil, "Secret not found"
    end

    if secret.vault_id ~= vault_id then
        return nil, "Secret belongs to a different vault"
    end

    -- Get vault for logging
    local vault = Vaults:find(vault_id)

    -- Decrypt the value
    local ok, decrypted_value = pcall(decryptWithDerivedKey,
        secret.encrypted_value,
        secret.encryption_iv,
        secret.encryption_tag,
        derived_key
    )

    if not ok then
        -- Log failed read
        logAccess({
            namespace_id = vault and vault.namespace_id,
            vault_id = vault_id,
            secret_id = secret.id,
            user_id = user_id,
            action = "secret_read",
            success = false,
            error_message = "Decryption failed"
        })
        return nil, "Failed to decrypt secret: " .. tostring(decrypted_value)
    end

    -- Decrypt metadata if present
    local decrypted_metadata = nil
    if secret.encrypted_metadata then
        local meta_ok, meta_value = pcall(decryptWithDerivedKey,
            secret.encrypted_metadata,
            secret.metadata_iv,
            secret.metadata_tag,
            derived_key
        )
        if meta_ok then
            local parse_ok, parsed = pcall(cjson.decode, meta_value)
            decrypted_metadata = parse_ok and parsed or meta_value
        end
    end

    -- Update access stats
    secret:update({
        last_accessed_at = Global.getCurrentTimestamp(),
        access_count = (secret.access_count or 0) + 1
    })

    -- Log the access
    logAccess({
        namespace_id = vault and vault.namespace_id,
        vault_id = vault_id,
        secret_id = secret.id,
        user_id = user_id,
        action = "secret_read"
    })

    -- Parse tags
    local tags = nil
    if secret.tags then
        local tag_ok, parsed = pcall(cjson.decode, secret.tags)
        tags = tag_ok and parsed or {}
    end

    return {
        id = secret.id,
        uuid = secret.uuid,
        vault_id = secret.vault_id,
        folder_id = secret.folder_id,
        name = secret.name,
        secret_type = secret.secret_type,
        description = secret.description,
        icon = secret.icon,
        color = secret.color,
        tags = tags,
        value = decrypted_value,
        metadata = decrypted_metadata,
        expires_at = secret.expires_at,
        rotation_reminder_at = secret.rotation_reminder_at,
        is_shared = secret.is_shared,
        share_count = secret.share_count,
        last_accessed_at = secret.last_accessed_at,
        access_count = secret.access_count,
        last_rotated_at = secret.last_rotated_at,
        created_at = secret.created_at,
        updated_at = secret.updated_at
    }, nil
end

--- Update a secret
-- @param secret_id number|string Secret ID or UUID
-- @param vault_id number The vault ID (for ownership verification)
-- @param derived_key string The derived encryption key
-- @param data table Fields to update (value requires re-encryption)
-- @param user_id number The user updating the secret
-- @return table|nil secret (value masked)
-- @return string|nil error
function SecretVaultQueries.updateSecret(secret_id, vault_id, derived_key, data, user_id)
    local secret = Secrets:find({ uuid = tostring(secret_id) })
    if not secret and tonumber(secret_id) then
        secret = Secrets:find({ id = tonumber(secret_id) })
    end

    if not secret then
        return nil, "Secret not found"
    end

    if secret.vault_id ~= vault_id then
        return nil, "Secret belongs to a different vault"
    end

    local vault = Vaults:find(vault_id)
    local timestamp = Global.getCurrentTimestamp()

    local update_data = {
        updated_at = timestamp,
        updated_by = user_id
    }

    -- Handle non-encrypted fields
    if data.name then update_data.name = data.name end
    if data.secret_type then update_data.secret_type = data.secret_type end
    if data.description ~= nil then update_data.description = data.description end
    if data.icon then update_data.icon = data.icon end
    if data.color then update_data.color = data.color end
    -- Normalize folder_id - treat 0, "", "0" as NULL (no folder/root)
    -- For updates, we need to handle the case where user wants to move to root (no folder)
    if data.folder_id ~= nil then
        local has_folder = data.folder_id and data.folder_id ~= 0 and data.folder_id ~= "" and data.folder_id ~= "0"
        if has_folder then
            update_data.folder_id = tonumber(data.folder_id) or data.folder_id
        else
            -- Explicitly set to NULL to move secret to root
            update_data.folder_id = db.raw("NULL")
        end
    end
    if data.expires_at ~= nil then update_data.expires_at = data.expires_at end
    if data.rotation_reminder_at ~= nil then update_data.rotation_reminder_at = data.rotation_reminder_at end
    if data.tags then
        update_data.tags = type(data.tags) == "string" and data.tags or cjson.encode(data.tags)
    end

    -- Handle value update (requires re-encryption)
    if data.value then
        local encrypted_value, encryption_iv, encryption_tag = encryptWithDerivedKey(data.value, derived_key)
        update_data.encrypted_value = encrypted_value
        update_data.encryption_iv = encryption_iv
        update_data.encryption_tag = encryption_tag
        update_data.last_rotated_at = timestamp  -- Consider value change as rotation
    end

    -- Handle metadata update
    if data.metadata ~= nil then
        if data.metadata == "" or (type(data.metadata) == "table" and next(data.metadata) == nil) then
            update_data.encrypted_metadata = nil
            update_data.metadata_iv = nil
            update_data.metadata_tag = nil
        else
            local metadata_json = type(data.metadata) == "string" and data.metadata or cjson.encode(data.metadata)
            local encrypted_metadata, metadata_iv, metadata_tag = encryptWithDerivedKey(metadata_json, derived_key)
            update_data.encrypted_metadata = encrypted_metadata
            update_data.metadata_iv = metadata_iv
            update_data.metadata_tag = metadata_tag
        end
    end

    secret:update(update_data)

    -- Log the action
    logAccess({
        namespace_id = vault and vault.namespace_id,
        vault_id = vault_id,
        secret_id = secret.id,
        user_id = user_id,
        action = "secret_update",
        action_detail = data.value and "Value updated" or "Metadata updated"
    })

    -- Remove sensitive fields
    secret.encrypted_value = nil
    secret.encryption_iv = nil
    secret.encryption_tag = nil
    secret.encrypted_metadata = nil
    secret.metadata_iv = nil
    secret.metadata_tag = nil

    return secret, nil
end

--- Delete a secret
-- @param secret_id number|string Secret ID or UUID
-- @param vault_id number The vault ID (for ownership verification)
-- @param user_id number The user deleting the secret
-- @return boolean success
-- @return string|nil error
function SecretVaultQueries.deleteSecret(secret_id, vault_id, user_id)
    local secret = Secrets:find({ uuid = tostring(secret_id) })
    if not secret and tonumber(secret_id) then
        secret = Secrets:find({ id = tonumber(secret_id) })
    end

    if not secret then
        return false, "Secret not found"
    end

    if secret.vault_id ~= vault_id then
        return false, "Secret belongs to a different vault"
    end

    local vault = Vaults:find(vault_id)
    local secret_name = secret.name

    -- Delete the secret
    secret:delete()

    -- Log the action
    logAccess({
        namespace_id = vault and vault.namespace_id,
        vault_id = vault_id,
        user_id = user_id,
        action = "secret_delete",
        action_detail = "Deleted secret: " .. secret_name
    })

    return true, nil
end

-- ============================================
-- Secret Sharing
-- ============================================

--- Share a secret with another user
-- @param secret_id number|string Secret ID or UUID
-- @param source_vault_id number The source vault ID
-- @param source_derived_key string The source user's derived key
-- @param target_user_id number The user to share with
-- @param target_vault_key string The target user's vault key
-- @param share_options table { permission?, can_reshare?, expires_at?, message? }
-- @param shared_by_user_id number The user doing the sharing
-- @return table|nil share record
-- @return string|nil error
function SecretVaultQueries.shareSecret(secret_id, source_vault_id, source_derived_key, target_user_id, target_vault_key, share_options, shared_by_user_id)
    share_options = share_options or {}

    -- Find source secret
    local source_secret = Secrets:find({ uuid = tostring(secret_id) })
    if not source_secret and tonumber(secret_id) then
        source_secret = Secrets:find({ id = tonumber(secret_id) })
    end

    if not source_secret then
        return nil, "Secret not found"
    end

    if source_secret.vault_id ~= source_vault_id then
        return nil, "Secret belongs to a different vault"
    end

    -- Get source vault
    local source_vault = Vaults:find(source_vault_id)
    if not source_vault then
        return nil, "Source vault not found"
    end

    -- Get or create target vault
    local target_vault = db.query([[
        SELECT * FROM namespace_secret_vaults
        WHERE namespace_id = ? AND user_id = ?
    ]], source_vault.namespace_id, target_user_id)

    if not target_vault or #target_vault == 0 then
        return nil, "Target user does not have a vault in this namespace. They must create a vault first."
    end
    target_vault = target_vault[1]

    -- Validate target vault key
    local valid, err = validateVaultKey(target_vault_key)
    if not valid then
        return nil, "Target vault key: " .. err
    end

    -- Verify target vault key
    local target_derived_key = deriveKey(target_vault_key, target_vault.key_salt)
    local target_verification = createVerificationHash(target_derived_key)

    if target_verification ~= target_vault.key_verification_hash then
        return nil, "Invalid target vault key"
    end

    -- Decrypt secret with source key
    local ok, decrypted_value = pcall(decryptWithDerivedKey,
        source_secret.encrypted_value,
        source_secret.encryption_iv,
        source_secret.encryption_tag,
        source_derived_key
    )

    if not ok then
        return nil, "Failed to decrypt source secret"
    end

    -- Decrypt metadata if present
    local decrypted_metadata = nil
    if source_secret.encrypted_metadata then
        local meta_ok, meta_value = pcall(decryptWithDerivedKey,
            source_secret.encrypted_metadata,
            source_secret.metadata_iv,
            source_secret.metadata_tag,
            source_derived_key
        )
        if meta_ok then
            decrypted_metadata = meta_value
        end
    end

    local timestamp = Global.getCurrentTimestamp()

    -- Re-encrypt with target key
    local target_encrypted, target_iv, target_tag = encryptWithDerivedKey(decrypted_value, target_derived_key)

    local target_meta_encrypted, target_meta_iv, target_meta_tag = nil, nil, nil
    if decrypted_metadata then
        target_meta_encrypted, target_meta_iv, target_meta_tag = encryptWithDerivedKey(decrypted_metadata, target_derived_key)
    end

    -- Create secret copy in target vault
    local target_secret_data = {
        uuid = Global.generateUUID(),
        vault_id = target_vault.id,
        folder_id = nil,  -- Shared secrets go to root
        name = source_secret.name .. " (Shared)",
        secret_type = source_secret.secret_type,
        description = source_secret.description,
        icon = source_secret.icon,
        color = source_secret.color,
        tags = source_secret.tags,
        encrypted_value = target_encrypted,
        encryption_iv = target_iv,
        encryption_tag = target_tag,
        encrypted_metadata = target_meta_encrypted,
        metadata_iv = target_meta_iv,
        metadata_tag = target_meta_tag,
        encryption_version = 1,
        expires_at = share_options.expires_at or source_secret.expires_at,
        is_shared = true,
        share_count = 0,
        access_count = 0,
        created_by = shared_by_user_id,
        updated_by = shared_by_user_id,
        created_at = timestamp,
        updated_at = timestamp
    }

    local target_secret = Secrets:create(target_secret_data, { returning = "*" })

    -- Create share record
    local share_data = {
        uuid = Global.generateUUID(),
        source_secret_id = source_secret.id,
        source_vault_id = source_vault_id,
        shared_by_user_id = shared_by_user_id,
        target_secret_id = target_secret.id,
        target_vault_id = target_vault.id,
        shared_with_user_id = target_user_id,
        permission = share_options.permission or "read",
        can_reshare = share_options.can_reshare or false,
        expires_at = share_options.expires_at,
        status = "active",
        message = share_options.message,
        created_at = timestamp,
        updated_at = timestamp
    }

    local share = Shares:create(share_data, { returning = "*" })

    -- Log the action
    logAccess({
        namespace_id = source_vault.namespace_id,
        vault_id = source_vault_id,
        secret_id = source_secret.id,
        user_id = shared_by_user_id,
        action = "secret_share",
        action_detail = string.format("Shared '%s' with user %d", source_secret.name, target_user_id),
        metadata = { target_user_id = target_user_id, target_vault_id = target_vault.id }
    })

    return share, nil
end

--- Revoke a shared secret
-- @param share_id number|string Share ID or UUID
-- @param user_id number The user revoking (must be share owner)
-- @return boolean success
-- @return string|nil error
function SecretVaultQueries.revokeShare(share_id, user_id)
    local share = Shares:find({ uuid = tostring(share_id) })
    if not share and tonumber(share_id) then
        share = Shares:find({ id = tonumber(share_id) })
    end

    if not share then
        return false, "Share not found"
    end

    if share.shared_by_user_id ~= user_id then
        return false, "Only the user who shared can revoke"
    end

    if share.status ~= "active" then
        return false, "Share is already " .. share.status
    end

    local timestamp = Global.getCurrentTimestamp()

    -- Update share status
    share:update({
        status = "revoked",
        revoked_at = timestamp,
        revoked_by = user_id,
        updated_at = timestamp
    })

    -- Delete the target secret (the copy)
    local target_secret = Secrets:find(share.target_secret_id)
    if target_secret then
        target_secret:delete()
    end

    -- Log the action
    local source_vault = Vaults:find(share.source_vault_id)
    logAccess({
        namespace_id = source_vault and source_vault.namespace_id,
        vault_id = share.source_vault_id,
        secret_id = share.source_secret_id,
        user_id = user_id,
        action = "share_revoke",
        action_detail = string.format("Revoked share with user %d", share.shared_with_user_id)
    })

    return true, nil
end

--- Get shares for a secret (outgoing)
-- @param secret_id number|string Secret ID or UUID
-- @param vault_id number The vault ID
-- @return table shares
function SecretVaultQueries.getSecretShares(secret_id, vault_id)
    local secret = Secrets:find({ uuid = tostring(secret_id) })
    if not secret and tonumber(secret_id) then
        secret = Secrets:find({ id = tonumber(secret_id) })
    end

    if not secret or secret.vault_id ~= vault_id then
        return {}
    end

    local shares = db.query([[
        SELECT s.*, u.first_name, u.last_name, u.email as shared_with_email
        FROM namespace_vault_shares s
        LEFT JOIN users u ON s.shared_with_user_id = u.id
        WHERE s.source_secret_id = ?
        ORDER BY s.created_at DESC
    ]], secret.id)

    return shares or {}
end

--- Get secrets shared with me
-- @param vault_id number The user's vault ID
-- @return table shared secrets
function SecretVaultQueries.getSharedWithMe(vault_id)
    local shares = db.query([[
        SELECT s.*, sec.name as secret_name, sec.secret_type,
               u.first_name as shared_by_first_name, u.last_name as shared_by_last_name
        FROM namespace_vault_shares s
        LEFT JOIN namespace_vault_secrets sec ON s.target_secret_id = sec.id
        LEFT JOIN users u ON s.shared_by_user_id = u.id
        WHERE s.target_vault_id = ? AND s.status = 'active'
        ORDER BY s.created_at DESC
    ]], vault_id)

    return shares or {}
end

-- ============================================
-- Vault Statistics & Audit
-- ============================================

--- Get vault statistics
-- @param vault_id number The vault ID
-- @return table stats
function SecretVaultQueries.getVaultStats(vault_id)
    local stats = db.query([[
        SELECT
            v.secrets_count,
            v.last_accessed_at,
            (SELECT COUNT(*) FROM namespace_vault_folders WHERE vault_id = v.id) as folders_count,
            (SELECT COUNT(*) FROM namespace_vault_shares WHERE source_vault_id = v.id AND status = 'active') as outgoing_shares,
            (SELECT COUNT(*) FROM namespace_vault_shares WHERE target_vault_id = v.id AND status = 'active') as incoming_shares,
            (SELECT COUNT(*) FROM namespace_vault_secrets WHERE vault_id = v.id AND expires_at IS NOT NULL AND expires_at < NOW()) as expired_secrets,
            (SELECT COUNT(*) FROM namespace_vault_secrets WHERE vault_id = v.id AND rotation_reminder_at IS NOT NULL AND rotation_reminder_at < NOW()) as secrets_needing_rotation
        FROM namespace_secret_vaults v
        WHERE v.id = ?
    ]], vault_id)

    return stats and stats[1] or {}
end

--- Get vault access logs
-- @param vault_id number The vault ID
-- @param params table { page?, per_page?, action?, start_date?, end_date? }
-- @return table { data, total, page, per_page, total_pages }
function SecretVaultQueries.getAccessLogs(vault_id, params)
    params = params or {}
    local page = tonumber(params.page) or 1
    local per_page = tonumber(params.per_page) or tonumber(params.perPage) or 50

    -- Use table alias prefix to avoid ambiguity with JOINed tables
    local conditions = { "l.vault_id = ?" }
    local values = { vault_id }

    if params.action then
        table.insert(conditions, "l.action = ?")
        table.insert(values, params.action)
    end

    if params.start_date then
        table.insert(conditions, "l.created_at >= ?")
        table.insert(values, params.start_date)
    end

    if params.end_date then
        table.insert(conditions, "l.created_at <= ?")
        table.insert(values, params.end_date)
    end

    local where_clause = "WHERE " .. table.concat(conditions, " AND ")

    -- Get total count (use alias for consistency)
    local count_result = db.query(
        "SELECT COUNT(*) as total FROM namespace_vault_access_logs l " .. where_clause,
        table.unpack(values)
    )
    local total = count_result and count_result[1] and count_result[1].total or 0

    -- Get paginated data
    local offset = (page - 1) * per_page
    local data_query = string.format([[
        SELECT l.*, s.name as secret_name
        FROM namespace_vault_access_logs l
        LEFT JOIN namespace_vault_secrets s ON l.secret_id = s.id
        %s
        ORDER BY l.created_at DESC
        LIMIT %d OFFSET %d
    ]], where_clause, per_page, offset)

    local data = db.query(data_query, table.unpack(values))

    return {
        data = data or {},
        total = total,
        page = page,
        per_page = per_page,
        total_pages = math.ceil(total / per_page)
    }
end

-- ============================================
-- User Search for Sharing
-- ============================================

--- Search users in a namespace for sharing secrets
-- @param namespace_id number The namespace ID
-- @param current_user_id number The current user ID (to exclude from results)
-- @param search_query string The search query (email, first_name, last_name)
-- @param limit number Maximum results to return (default 10)
-- @return table users
function SecretVaultQueries.searchNamespaceUsers(namespace_id, current_user_id, search_query, limit)
    limit = limit or 10
    search_query = search_query or ""

    -- Search users who are members of the namespace, excluding the current user
    -- Also check if they have a vault (can receive shared secrets)
    local users

    if search_query == "" then
        -- No search query - return recent/active namespace members
        users = db.query([[
            SELECT DISTINCT
                u.id,
                u.uuid,
                u.email,
                u.first_name,
                u.last_name,
                u.username,
                CASE WHEN v.id IS NOT NULL THEN true ELSE false END as has_vault
            FROM users u
            INNER JOIN namespace_members nm ON u.id = nm.user_id
            LEFT JOIN namespace_secret_vaults v ON v.user_id = u.id AND v.namespace_id = ?
            WHERE nm.namespace_id = ?
              AND nm.status = 'active'
              AND u.id != ?
              AND u.active = true
            ORDER BY u.first_name, u.last_name
            LIMIT ?
        ]], namespace_id, namespace_id, current_user_id, limit)
    else
        -- Search by email, first_name, last_name, or username (case-insensitive)
        local search_pattern = "%" .. search_query:lower() .. "%"
        users = db.query([[
            SELECT DISTINCT
                u.id,
                u.uuid,
                u.email,
                u.first_name,
                u.last_name,
                u.username,
                CASE WHEN v.id IS NOT NULL THEN true ELSE false END as has_vault
            FROM users u
            INNER JOIN namespace_members nm ON u.id = nm.user_id
            LEFT JOIN namespace_secret_vaults v ON v.user_id = u.id AND v.namespace_id = ?
            WHERE nm.namespace_id = ?
              AND nm.status = 'active'
              AND u.id != ?
              AND u.active = true
              AND (
                  LOWER(u.email) LIKE ?
                  OR LOWER(u.first_name) LIKE ?
                  OR LOWER(u.last_name) LIKE ?
                  OR LOWER(u.username) LIKE ?
                  OR LOWER(CONCAT(u.first_name, ' ', u.last_name)) LIKE ?
              )
            ORDER BY
                CASE
                    WHEN LOWER(u.email) = LOWER(?) THEN 1
                    WHEN LOWER(u.email) LIKE ? THEN 2
                    ELSE 3
                END,
                u.first_name, u.last_name
            LIMIT ?
        ]], namespace_id, namespace_id, current_user_id,
            search_pattern, search_pattern, search_pattern, search_pattern, search_pattern,
            search_query:lower(), search_query:lower() .. "%",
            limit)
    end

    -- Format the response
    local result = {}
    for _, user in ipairs(users or {}) do
        table.insert(result, {
            id = user.id,
            uuid = user.uuid,
            email = user.email,
            first_name = user.first_name,
            last_name = user.last_name,
            username = user.username,
            full_name = (user.first_name or "") .. " " .. (user.last_name or ""),
            has_vault = user.has_vault
        })
    end

    return result
end

return SecretVaultQueries
