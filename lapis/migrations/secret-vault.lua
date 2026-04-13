--[[
    Secret Vault System Migrations
    ==============================

    A secure, multi-tenant secret management system with user-provided encryption keys.

    SECURITY ARCHITECTURE:
    ======================
    1. User-Provided Encryption Keys:
       - Each user provides their own 16-character security key (vault key)
       - The vault key is NEVER stored in the database
       - User must enter their vault key to encrypt/decrypt secrets
       - If the vault key is lost, secrets cannot be recovered

    2. Key Derivation:
       - User's 16-char key is used to derive an AES-256 key using PBKDF2
       - A unique salt is stored per vault for key derivation
       - 100,000 iterations for brute-force resistance

    3. Encryption:
       - Secrets are encrypted using AES-256-GCM (authenticated encryption)
       - Each secret has its own random IV/nonce
       - Authentication tag prevents tampering

    4. Secret Sharing:
       - When sharing, the secret is decrypted with source user's key
       - Then re-encrypted with destination user's key
       - A copy is created under the destination user's vault

    5. Multi-Tenant Isolation:
       - Vaults are scoped to both namespace AND user
       - Users can only access their own vault secrets
       - Admins can share secrets within their namespace

    Tables:
    - namespace_secret_vaults: User's vault configuration per namespace
    - namespace_vault_folders: Organize secrets into folders
    - namespace_vault_secrets: The actual encrypted secrets
    - namespace_vault_shares: Track shared secrets between users
    - namespace_vault_access_logs: Audit trail for all vault operations
]]

local schema = require("lapis.db.schema")
local types = schema.types
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

-- Helper to check if column exists
local function column_exists(table_name, column_name)
    local result = db.query([[
        SELECT column_name FROM information_schema.columns
        WHERE table_name = ? AND column_name = ?
    ]], table_name, column_name)
    return #result > 0
end

-- Helper to safely add foreign key
local function add_foreign_key(table_name, column_name, ref_table, ref_column, constraint_name, on_delete)
    on_delete = on_delete or "CASCADE"
    pcall(function()
        db.query(string.format([[
            ALTER TABLE %s
            ADD CONSTRAINT %s
            FOREIGN KEY (%s) REFERENCES %s(%s) ON DELETE %s
        ]], table_name, constraint_name, column_name, ref_table, ref_column, on_delete))
    end)
end

return {
    -- ========================================
    -- [1] Create namespace_secret_vaults table
    -- User's vault configuration per namespace
    -- ========================================
    [1] = function()
        if table_exists("namespace_secret_vaults") then return end

        schema.create_table("namespace_secret_vaults", {
            { "id", types.serial },
            { "uuid", types.varchar({ unique = true }) },
            { "namespace_id", types.foreign_key },
            { "user_id", types.foreign_key },

            -- Vault Configuration
            { "name", types.varchar({ default = "'My Vault'" }) },

            -- Key Derivation Salt (stored, used with user's key)
            -- Random 32-byte salt, base64 encoded
            { "key_salt", types.varchar },

            -- Key verification hash (to verify user entered correct key)
            -- Hash of derived key - NOT the key itself
            { "key_verification_hash", types.varchar },

            -- Vault Status
            { "status", types.varchar({ default = "'active'" }) },
            { "locked_at", types.time({ null = true }) },
            { "lock_reason", types.text({ null = true }) },
            { "failed_attempts", types.integer({ default = 0 }) },
            { "last_failed_attempt_at", types.time({ null = true }) },

            -- Statistics
            { "secrets_count", types.integer({ default = 0 }) },
            { "last_accessed_at", types.time({ null = true }) },

            -- Metadata
            { "created_at", types.time({ null = true }) },
            { "updated_at", types.time({ null = true }) },

            "PRIMARY KEY (id)",
            "FOREIGN KEY (namespace_id) REFERENCES namespaces(id) ON DELETE CASCADE",
            "FOREIGN KEY (user_id) REFERENCES users(id) ON DELETE CASCADE"
        })

        -- One vault per user per namespace
        pcall(function()
            db.query([[
                ALTER TABLE namespace_secret_vaults
                ADD CONSTRAINT namespace_secret_vaults_unique_user
                UNIQUE (namespace_id, user_id)
            ]])
        end)

        -- Status constraint
        pcall(function()
            db.query([[
                ALTER TABLE namespace_secret_vaults
                ADD CONSTRAINT namespace_secret_vaults_status_check
                CHECK (status IN ('active', 'locked', 'suspended'))
            ]])
        end)
    end,

    -- ========================================
    -- [2] Create namespace_secret_vaults indexes
    -- ========================================
    [2] = function()
        pcall(function() schema.create_index("namespace_secret_vaults", "uuid") end)
        pcall(function() schema.create_index("namespace_secret_vaults", "namespace_id") end)
        pcall(function() schema.create_index("namespace_secret_vaults", "user_id") end)
        pcall(function() schema.create_index("namespace_secret_vaults", "status") end)
        pcall(function() schema.create_index("namespace_secret_vaults", "namespace_id", "user_id") end)
    end,

    -- ========================================
    -- [3] Create namespace_vault_folders table
    -- Organize secrets into hierarchical folders
    -- ========================================
    [3] = function()
        if table_exists("namespace_vault_folders") then return end

        schema.create_table("namespace_vault_folders", {
            { "id", types.serial },
            { "uuid", types.varchar({ unique = true }) },
            { "vault_id", types.foreign_key },
            { "parent_folder_id", types.integer({ null = true }) },

            -- Folder Info
            { "name", types.varchar },
            { "icon", types.varchar({ null = true, default = "'folder'" }) },
            { "color", types.varchar({ null = true, default = "'gray'" }) },
            { "description", types.text({ null = true }) },

            -- Hierarchy
            { "path", types.text({ default = "'/'" }) },  -- Materialized path for fast queries
            { "depth", types.integer({ default = 0 }) },

            -- Statistics
            { "secrets_count", types.integer({ default = 0 }) },

            -- Metadata
            { "created_at", types.time({ null = true }) },
            { "updated_at", types.time({ null = true }) },

            "PRIMARY KEY (id)",
            "FOREIGN KEY (vault_id) REFERENCES namespace_secret_vaults(id) ON DELETE CASCADE"
        })

        -- Self-referential FK for parent folder
        add_foreign_key("namespace_vault_folders", "parent_folder_id", "namespace_vault_folders", "id",
            "namespace_vault_folders_parent_fk", "CASCADE")

        -- Unique folder name within same parent
        pcall(function()
            db.query([[
                ALTER TABLE namespace_vault_folders
                ADD CONSTRAINT namespace_vault_folders_unique_name
                UNIQUE (vault_id, parent_folder_id, name)
            ]])
        end)
    end,

    -- ========================================
    -- [4] Create namespace_vault_folders indexes
    -- ========================================
    [4] = function()
        pcall(function() schema.create_index("namespace_vault_folders", "uuid") end)
        pcall(function() schema.create_index("namespace_vault_folders", "vault_id") end)
        pcall(function() schema.create_index("namespace_vault_folders", "parent_folder_id") end)
        pcall(function() schema.create_index("namespace_vault_folders", "path") end)
    end,

    -- ========================================
    -- [5] Create namespace_vault_secrets table
    -- Encrypted secrets storage
    -- ========================================
    [5] = function()
        if table_exists("namespace_vault_secrets") then return end

        schema.create_table("namespace_vault_secrets", {
            { "id", types.serial },
            { "uuid", types.varchar({ unique = true }) },
            { "vault_id", types.foreign_key },
            { "folder_id", types.integer({ null = true }) },

            -- Secret Metadata (not encrypted)
            { "name", types.varchar },
            { "secret_type", types.varchar({ default = "'generic'" }) },
            { "description", types.text({ null = true }) },
            { "icon", types.varchar({ null = true, default = "'key'" }) },
            { "color", types.varchar({ null = true, default = "'blue'" }) },
            { "tags", types.text({ null = true }) },  -- JSON array of tags

            -- Encrypted Data
            { "encrypted_value", types.text },  -- AES-256-GCM encrypted
            { "encryption_iv", types.varchar },  -- Random IV per secret (base64)
            { "encryption_tag", types.varchar },  -- GCM auth tag (base64)
            { "encryption_version", types.integer({ default = 1 }) },

            -- Optional encrypted metadata (JSON with sensitive fields)
            { "encrypted_metadata", types.text({ null = true }) },
            { "metadata_iv", types.varchar({ null = true }) },
            { "metadata_tag", types.varchar({ null = true }) },

            -- Expiration
            { "expires_at", types.time({ null = true }) },
            { "rotation_reminder_at", types.time({ null = true }) },

            -- Access Control
            { "is_shared", types.boolean({ default = false }) },
            { "share_count", types.integer({ default = 0 }) },

            -- Audit
            { "last_accessed_at", types.time({ null = true }) },
            { "access_count", types.integer({ default = 0 }) },
            { "last_rotated_at", types.time({ null = true }) },

            -- Metadata
            { "created_by", types.integer({ null = true }) },
            { "updated_by", types.integer({ null = true }) },
            { "created_at", types.time({ null = true }) },
            { "updated_at", types.time({ null = true }) },

            "PRIMARY KEY (id)",
            "FOREIGN KEY (vault_id) REFERENCES namespace_secret_vaults(id) ON DELETE CASCADE"
        })

        -- FK for folder
        add_foreign_key("namespace_vault_secrets", "folder_id", "namespace_vault_folders", "id",
            "namespace_vault_secrets_folder_fk", "SET NULL")

        -- FK for created_by
        add_foreign_key("namespace_vault_secrets", "created_by", "users", "id",
            "namespace_vault_secrets_created_by_fk", "SET NULL")

        -- FK for updated_by
        add_foreign_key("namespace_vault_secrets", "updated_by", "users", "id",
            "namespace_vault_secrets_updated_by_fk", "SET NULL")

        -- Secret type constraint
        pcall(function()
            db.query([[
                ALTER TABLE namespace_vault_secrets
                ADD CONSTRAINT namespace_vault_secrets_type_check
                CHECK (secret_type IN (
                    'generic',
                    'password',
                    'api_key',
                    'ssh_key',
                    'certificate',
                    'database',
                    'oauth_token',
                    'credit_card',
                    'note',
                    'env_variable',
                    'license_key',
                    'webhook_secret',
                    'encryption_key'
                ))
            ]])
        end)

        -- Unique secret name within same folder in vault
        pcall(function()
            db.query([[
                ALTER TABLE namespace_vault_secrets
                ADD CONSTRAINT namespace_vault_secrets_unique_name
                UNIQUE (vault_id, folder_id, name)
            ]])
        end)
    end,

    -- ========================================
    -- [6] Create namespace_vault_secrets indexes
    -- ========================================
    [6] = function()
        pcall(function() schema.create_index("namespace_vault_secrets", "uuid") end)
        pcall(function() schema.create_index("namespace_vault_secrets", "vault_id") end)
        pcall(function() schema.create_index("namespace_vault_secrets", "folder_id") end)
        pcall(function() schema.create_index("namespace_vault_secrets", "secret_type") end)
        pcall(function() schema.create_index("namespace_vault_secrets", "is_shared") end)
        pcall(function() schema.create_index("namespace_vault_secrets", "expires_at") end)
        pcall(function() schema.create_index("namespace_vault_secrets", "created_at") end)
        pcall(function() schema.create_index("namespace_vault_secrets", "name") end)

        -- Full-text search on name and description
        pcall(function()
            db.query([[
                CREATE INDEX namespace_vault_secrets_search_idx
                ON namespace_vault_secrets
                USING gin(to_tsvector('english', name || ' ' || COALESCE(description, '')))
            ]])
        end)
    end,

    -- ========================================
    -- [7] Create namespace_vault_shares table
    -- Track shared secrets between users
    -- ========================================
    [7] = function()
        if table_exists("namespace_vault_shares") then return end

        schema.create_table("namespace_vault_shares", {
            { "id", types.serial },
            { "uuid", types.varchar({ unique = true }) },

            -- Source (who shared)
            { "source_secret_id", types.foreign_key },
            { "source_vault_id", types.foreign_key },
            { "shared_by_user_id", types.foreign_key },

            -- Destination (who received)
            { "target_secret_id", types.foreign_key },  -- The copy in target vault
            { "target_vault_id", types.foreign_key },
            { "shared_with_user_id", types.foreign_key },

            -- Share Settings
            { "permission", types.varchar({ default = "'read'" }) },  -- read, write
            { "can_reshare", types.boolean({ default = false }) },
            { "expires_at", types.time({ null = true }) },

            -- Status
            { "status", types.varchar({ default = "'active'" }) },
            { "revoked_at", types.time({ null = true }) },
            { "revoked_by", types.integer({ null = true }) },

            -- Metadata
            { "message", types.text({ null = true }) },  -- Optional message when sharing
            { "created_at", types.time({ null = true }) },
            { "updated_at", types.time({ null = true }) },

            "PRIMARY KEY (id)",
            "FOREIGN KEY (source_secret_id) REFERENCES namespace_vault_secrets(id) ON DELETE CASCADE",
            "FOREIGN KEY (source_vault_id) REFERENCES namespace_secret_vaults(id) ON DELETE CASCADE",
            "FOREIGN KEY (shared_by_user_id) REFERENCES users(id) ON DELETE CASCADE",
            "FOREIGN KEY (target_secret_id) REFERENCES namespace_vault_secrets(id) ON DELETE CASCADE",
            "FOREIGN KEY (target_vault_id) REFERENCES namespace_secret_vaults(id) ON DELETE CASCADE",
            "FOREIGN KEY (shared_with_user_id) REFERENCES users(id) ON DELETE CASCADE"
        })

        -- Permission constraint
        pcall(function()
            db.query([[
                ALTER TABLE namespace_vault_shares
                ADD CONSTRAINT namespace_vault_shares_permission_check
                CHECK (permission IN ('read', 'write'))
            ]])
        end)

        -- Status constraint
        pcall(function()
            db.query([[
                ALTER TABLE namespace_vault_shares
                ADD CONSTRAINT namespace_vault_shares_status_check
                CHECK (status IN ('active', 'revoked', 'expired'))
            ]])
        end)

        -- Unique share per source-target pair
        pcall(function()
            db.query([[
                ALTER TABLE namespace_vault_shares
                ADD CONSTRAINT namespace_vault_shares_unique_share
                UNIQUE (source_secret_id, shared_with_user_id)
            ]])
        end)
    end,

    -- ========================================
    -- [8] Create namespace_vault_shares indexes
    -- ========================================
    [8] = function()
        pcall(function() schema.create_index("namespace_vault_shares", "uuid") end)
        pcall(function() schema.create_index("namespace_vault_shares", "source_secret_id") end)
        pcall(function() schema.create_index("namespace_vault_shares", "source_vault_id") end)
        pcall(function() schema.create_index("namespace_vault_shares", "shared_by_user_id") end)
        pcall(function() schema.create_index("namespace_vault_shares", "target_secret_id") end)
        pcall(function() schema.create_index("namespace_vault_shares", "target_vault_id") end)
        pcall(function() schema.create_index("namespace_vault_shares", "shared_with_user_id") end)
        pcall(function() schema.create_index("namespace_vault_shares", "status") end)
        pcall(function() schema.create_index("namespace_vault_shares", "expires_at") end)
    end,

    -- ========================================
    -- [9] Create namespace_vault_access_logs table
    -- Comprehensive audit trail
    -- ========================================
    [9] = function()
        if table_exists("namespace_vault_access_logs") then return end

        db.query([[
            CREATE TABLE namespace_vault_access_logs (
                id BIGSERIAL PRIMARY KEY,
                uuid VARCHAR(255) NOT NULL UNIQUE,

                -- Context
                namespace_id INTEGER NOT NULL REFERENCES namespaces(id) ON DELETE CASCADE,
                vault_id INTEGER REFERENCES namespace_secret_vaults(id) ON DELETE SET NULL,
                secret_id INTEGER REFERENCES namespace_vault_secrets(id) ON DELETE SET NULL,
                folder_id INTEGER REFERENCES namespace_vault_folders(id) ON DELETE SET NULL,
                user_id INTEGER REFERENCES users(id) ON DELETE SET NULL,

                -- Action Details
                action VARCHAR(50) NOT NULL,
                action_detail TEXT,

                -- Request Info
                ip_address VARCHAR(45),
                user_agent TEXT,
                request_id VARCHAR(255),

                -- Result
                success BOOLEAN NOT NULL DEFAULT true,
                error_message TEXT,

                -- Metadata
                metadata JSONB DEFAULT '{}',
                created_at TIMESTAMP WITHOUT TIME ZONE NOT NULL DEFAULT NOW()
            )
        ]])

        -- Action constraint
        pcall(function()
            db.query([[
                ALTER TABLE namespace_vault_access_logs
                ADD CONSTRAINT namespace_vault_access_logs_action_check
                CHECK (action IN (
                    'vault_create',
                    'vault_unlock',
                    'vault_lock',
                    'vault_key_change',
                    'vault_delete',
                    'secret_create',
                    'secret_read',
                    'secret_update',
                    'secret_delete',
                    'secret_rotate',
                    'secret_share',
                    'share_accept',
                    'share_revoke',
                    'folder_create',
                    'folder_update',
                    'folder_delete',
                    'bulk_import',
                    'bulk_export',
                    'failed_unlock'
                ))
            ]])
        end)

        -- Partition by month for better performance
        pcall(function()
            db.query([[
                CREATE INDEX namespace_vault_access_logs_created_at_idx
                ON namespace_vault_access_logs (created_at DESC)
            ]])
        end)
    end,

    -- ========================================
    -- [10] Create namespace_vault_access_logs indexes
    -- ========================================
    [10] = function()
        pcall(function() schema.create_index("namespace_vault_access_logs", "namespace_id") end)
        pcall(function() schema.create_index("namespace_vault_access_logs", "vault_id") end)
        pcall(function() schema.create_index("namespace_vault_access_logs", "secret_id") end)
        pcall(function() schema.create_index("namespace_vault_access_logs", "user_id") end)
        pcall(function() schema.create_index("namespace_vault_access_logs", "action") end)
        pcall(function() schema.create_index("namespace_vault_access_logs", "success") end)
        pcall(function() schema.create_index("namespace_vault_access_logs", "ip_address") end)

        -- Composite index for common queries
        pcall(function()
            db.query([[
                CREATE INDEX namespace_vault_access_logs_audit_idx
                ON namespace_vault_access_logs (namespace_id, user_id, created_at DESC)
            ]])
        end)

        -- BRIN index for time-based queries (efficient for append-only)
        pcall(function()
            db.query([[
                CREATE INDEX namespace_vault_access_logs_created_at_brin
                ON namespace_vault_access_logs USING BRIN (created_at)
            ]])
        end)
    end,

    -- ========================================
    -- [11] Create vault secrets count trigger
    -- ========================================
    [11] = function()
        pcall(function()
            db.query([[
                CREATE OR REPLACE FUNCTION update_vault_secrets_count()
                RETURNS TRIGGER AS $$
                BEGIN
                    IF TG_OP = 'INSERT' THEN
                        UPDATE namespace_secret_vaults
                        SET secrets_count = secrets_count + 1,
                            updated_at = NOW()
                        WHERE id = NEW.vault_id;

                        IF NEW.folder_id IS NOT NULL THEN
                            UPDATE namespace_vault_folders
                            SET secrets_count = secrets_count + 1,
                                updated_at = NOW()
                            WHERE id = NEW.folder_id;
                        END IF;

                        RETURN NEW;
                    ELSIF TG_OP = 'DELETE' THEN
                        UPDATE namespace_secret_vaults
                        SET secrets_count = GREATEST(0, secrets_count - 1),
                            updated_at = NOW()
                        WHERE id = OLD.vault_id;

                        IF OLD.folder_id IS NOT NULL THEN
                            UPDATE namespace_vault_folders
                            SET secrets_count = GREATEST(0, secrets_count - 1),
                                updated_at = NOW()
                            WHERE id = OLD.folder_id;
                        END IF;

                        RETURN OLD;
                    ELSIF TG_OP = 'UPDATE' THEN
                        -- Handle folder change
                        IF OLD.folder_id IS DISTINCT FROM NEW.folder_id THEN
                            IF OLD.folder_id IS NOT NULL THEN
                                UPDATE namespace_vault_folders
                                SET secrets_count = GREATEST(0, secrets_count - 1),
                                    updated_at = NOW()
                                WHERE id = OLD.folder_id;
                            END IF;

                            IF NEW.folder_id IS NOT NULL THEN
                                UPDATE namespace_vault_folders
                                SET secrets_count = secrets_count + 1,
                                    updated_at = NOW()
                                WHERE id = NEW.folder_id;
                            END IF;
                        END IF;

                        RETURN NEW;
                    END IF;

                    RETURN NULL;
                END;
                $$ LANGUAGE plpgsql;
            ]])
        end)

        pcall(function()
            db.query([[
                DROP TRIGGER IF EXISTS vault_secrets_count_trigger ON namespace_vault_secrets;
                CREATE TRIGGER vault_secrets_count_trigger
                AFTER INSERT OR UPDATE OR DELETE ON namespace_vault_secrets
                FOR EACH ROW EXECUTE FUNCTION update_vault_secrets_count();
            ]])
        end)
    end,

    -- ========================================
    -- [12] Create share count trigger
    -- ========================================
    [12] = function()
        pcall(function()
            db.query([[
                CREATE OR REPLACE FUNCTION update_secret_share_count()
                RETURNS TRIGGER AS $$
                BEGIN
                    IF TG_OP = 'INSERT' THEN
                        UPDATE namespace_vault_secrets
                        SET share_count = share_count + 1,
                            is_shared = true,
                            updated_at = NOW()
                        WHERE id = NEW.source_secret_id;

                        RETURN NEW;
                    ELSIF TG_OP = 'DELETE' THEN
                        UPDATE namespace_vault_secrets
                        SET share_count = GREATEST(0, share_count - 1),
                            updated_at = NOW()
                        WHERE id = OLD.source_secret_id;

                        -- Update is_shared flag if no more shares
                        UPDATE namespace_vault_secrets
                        SET is_shared = false
                        WHERE id = OLD.source_secret_id
                        AND share_count = 0;

                        RETURN OLD;
                    END IF;

                    RETURN NULL;
                END;
                $$ LANGUAGE plpgsql;
            ]])
        end)

        pcall(function()
            db.query([[
                DROP TRIGGER IF EXISTS secret_share_count_trigger ON namespace_vault_shares;
                CREATE TRIGGER secret_share_count_trigger
                AFTER INSERT OR DELETE ON namespace_vault_shares
                FOR EACH ROW EXECUTE FUNCTION update_secret_share_count();
            ]])
        end)
    end,

    -- ========================================
    -- [13] Add vault permissions to namespace roles
    -- ========================================
    [13] = function()
        local cjson = require("cjson.safe")

        -- Get all namespace roles
        local roles = db.query([[
            SELECT id, permissions FROM namespace_roles
            WHERE role_name IN ('owner', 'admin', 'manager', 'member', 'viewer')
        ]])

        local role_permissions = {
            owner = { "create", "read", "update", "delete", "share", "manage" },
            admin = { "create", "read", "update", "delete", "share" },
            manager = { "create", "read", "update", "share" },
            member = { "create", "read", "update" },
            viewer = { "read" }
        }

        for _, role in ipairs(roles or {}) do
            local ok, perms = pcall(cjson.decode, role.permissions or "{}")
            if ok and type(perms) == "table" then
                -- Check role_name from a separate query
                local role_info = db.query("SELECT role_name FROM namespace_roles WHERE id = ?", role.id)
                if role_info and #role_info > 0 then
                    local role_name = role_info[1].role_name
                    if role_permissions[role_name] and not perms.vault then
                        perms.vault = role_permissions[role_name]
                        local new_perms = cjson.encode(perms)
                        db.update("namespace_roles", { permissions = new_perms }, { id = role.id })
                    end
                end
            end
        end
    end,

    -- ========================================
    -- [14] Add vault module to modules table
    -- ========================================
    [14] = function()
        local MigrationUtils = require("helper.migration-utils")

        -- Check if vault module exists
        local exists = db.query([[
            SELECT id FROM modules WHERE machine_name = 'vault'
        ]])

        if not exists or #exists == 0 then
            db.query([[
                INSERT INTO modules (uuid, machine_name, name, description, priority, created_at, updated_at)
                VALUES (?, 'vault', 'Secret Vault', 'Secure secret management with user-provided encryption keys', 'high', ?, ?)
            ]], MigrationUtils.generateUUID(), MigrationUtils.getCurrentTimestamp(), MigrationUtils.getCurrentTimestamp())
        end
    end,

    -- ========================================
    -- [15] Create expired shares cleanup function
    -- ========================================
    [15] = function()
        pcall(function()
            db.query([[
                CREATE OR REPLACE FUNCTION cleanup_expired_vault_shares()
                RETURNS INTEGER AS $$
                DECLARE
                    expired_count INTEGER;
                BEGIN
                    UPDATE namespace_vault_shares
                    SET status = 'expired',
                        updated_at = NOW()
                    WHERE status = 'active'
                    AND expires_at IS NOT NULL
                    AND expires_at < NOW();

                    GET DIAGNOSTICS expired_count = ROW_COUNT;

                    RETURN expired_count;
                END;
                $$ LANGUAGE plpgsql;
            ]])
        end)
    end,

    -- ========================================
    -- [16] Create secret rotation reminder view
    -- ========================================
    [16] = function()
        pcall(function()
            db.query([[
                CREATE OR REPLACE VIEW vault_secrets_needing_rotation AS
                SELECT
                    s.id,
                    s.uuid,
                    s.name,
                    s.secret_type,
                    s.vault_id,
                    v.user_id,
                    v.namespace_id,
                    s.rotation_reminder_at,
                    s.last_rotated_at,
                    s.expires_at,
                    CASE
                        WHEN s.expires_at IS NOT NULL AND s.expires_at < NOW() THEN 'expired'
                        WHEN s.expires_at IS NOT NULL AND s.expires_at < NOW() + INTERVAL '7 days' THEN 'expiring_soon'
                        WHEN s.rotation_reminder_at IS NOT NULL AND s.rotation_reminder_at < NOW() THEN 'rotation_due'
                        ELSE 'ok'
                    END as status
                FROM namespace_vault_secrets s
                JOIN namespace_secret_vaults v ON s.vault_id = v.id
                WHERE
                    (s.rotation_reminder_at IS NOT NULL AND s.rotation_reminder_at < NOW() + INTERVAL '7 days')
                    OR (s.expires_at IS NOT NULL AND s.expires_at < NOW() + INTERVAL '7 days')
                ORDER BY
                    CASE
                        WHEN s.expires_at < NOW() THEN 1
                        WHEN s.rotation_reminder_at < NOW() THEN 2
                        ELSE 3
                    END,
                    COALESCE(s.expires_at, s.rotation_reminder_at) ASC;
            ]])
        end)
    end,

    -- ========================================
    -- [17] Fix folder_id default value
    -- Remove any default value on folder_id columns
    -- ========================================
    [17] = function()
        -- Remove default from namespace_vault_secrets.folder_id if it exists
        pcall(function()
            db.query([[
                ALTER TABLE namespace_vault_secrets
                ALTER COLUMN folder_id DROP DEFAULT
            ]])
        end)

        -- Remove default from namespace_vault_folders.parent_folder_id if it exists
        pcall(function()
            db.query([[
                ALTER TABLE namespace_vault_folders
                ALTER COLUMN parent_folder_id DROP DEFAULT
            ]])
        end)

        -- Update any existing rows with folder_id = 0 to NULL
        pcall(function()
            db.query([[
                UPDATE namespace_vault_secrets
                SET folder_id = NULL
                WHERE folder_id = 0
            ]])
        end)

        -- Update any existing rows with parent_folder_id = 0 to NULL
        pcall(function()
            db.query([[
                UPDATE namespace_vault_folders
                SET parent_folder_id = NULL
                WHERE parent_folder_id = 0
            ]])
        end)
    end,
}
