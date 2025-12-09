--[[
    Services Module Migrations

    Purpose: Enable namespace-scoped GitHub workflow triggering with secure secrets management.

    Security Architecture:
    ======================
    - Secrets are encrypted at rest using AES-128-CBC (Global.encryptSecret)
    - Secrets are NEVER exposed in API responses
    - Secrets are only decrypted server-side when triggering GitHub workflows
    - All services are namespace-scoped for tenant isolation

    Tables:
    - namespace_services: Service definitions with GitHub workflow configuration
    - namespace_service_secrets: Encrypted secrets for workflow inputs
    - namespace_service_deployments: Deployment history and audit trail
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
    -- [1] Create namespace_services table
    -- ========================================
    [1] = function()
        if table_exists("namespace_services") then return end

        schema.create_table("namespace_services", {
            { "id", types.serial },
            { "uuid", types.varchar({ unique = true }) },
            { "namespace_id", types.foreign_key },
            { "name", types.varchar },
            { "description", types.text({ null = true }) },
            { "icon", types.varchar({ null = true, default = "'server'" }) },
            { "color", types.varchar({ null = true, default = "'blue'" }) },

            -- GitHub Configuration
            { "github_owner", types.varchar },
            { "github_repo", types.varchar },
            { "github_workflow_file", types.varchar },
            { "github_branch", types.varchar({ default = "'main'" }) },

            -- Service Status
            { "status", types.varchar({ default = "'active'" }) },

            -- Deployment Stats
            { "last_deployment_at", types.time({ null = true }) },
            { "last_deployment_status", types.varchar({ null = true }) },
            { "deployment_count", types.integer({ default = 0 }) },
            { "success_count", types.integer({ default = 0 }) },
            { "failure_count", types.integer({ default = 0 }) },

            -- Metadata
            { "created_by", types.integer({ null = true }) },
            { "updated_by", types.integer({ null = true }) },
            { "created_at", types.time({ null = true }) },
            { "updated_at", types.time({ null = true }) },

            "PRIMARY KEY (id)",
            "FOREIGN KEY (namespace_id) REFERENCES namespaces(id) ON DELETE CASCADE"
        })

        -- Status constraint
        pcall(function()
            db.query([[
                ALTER TABLE namespace_services
                ADD CONSTRAINT namespace_services_status_check
                CHECK (status IN ('active', 'inactive', 'archived'))
            ]])
        end)

        -- Unique constraint on name within namespace
        pcall(function()
            db.query([[
                ALTER TABLE namespace_services
                ADD CONSTRAINT namespace_services_unique_name
                UNIQUE (namespace_id, name)
            ]])
        end)
    end,

    -- ========================================
    -- [2] Create namespace_services indexes
    -- ========================================
    [2] = function()
        pcall(function() schema.create_index("namespace_services", "uuid") end)
        pcall(function() schema.create_index("namespace_services", "namespace_id") end)
        pcall(function() schema.create_index("namespace_services", "status") end)
        pcall(function() schema.create_index("namespace_services", "github_owner") end)
        pcall(function() schema.create_index("namespace_services", "github_repo") end)
        pcall(function() schema.create_index("namespace_services", "created_at") end)
        pcall(function() schema.create_index("namespace_services", "last_deployment_at") end)
    end,

    -- ========================================
    -- [3] Create namespace_service_secrets table
    -- Stores encrypted secrets for workflow inputs
    -- ========================================
    [3] = function()
        if table_exists("namespace_service_secrets") then return end

        schema.create_table("namespace_service_secrets", {
            { "id", types.serial },
            { "uuid", types.varchar({ unique = true }) },
            { "service_id", types.foreign_key },
            { "key", types.varchar },
            { "value", types.text },  -- Encrypted using Global.encryptSecret
            { "description", types.text({ null = true }) },
            { "is_required", types.boolean({ default = false }) },

            -- Metadata
            { "created_by", types.integer({ null = true }) },
            { "updated_by", types.integer({ null = true }) },
            { "created_at", types.time({ null = true }) },
            { "updated_at", types.time({ null = true }) },

            "PRIMARY KEY (id)",
            "FOREIGN KEY (service_id) REFERENCES namespace_services(id) ON DELETE CASCADE"
        })

        -- Unique constraint on key within service
        pcall(function()
            db.query([[
                ALTER TABLE namespace_service_secrets
                ADD CONSTRAINT namespace_service_secrets_unique_key
                UNIQUE (service_id, key)
            ]])
        end)
    end,

    -- ========================================
    -- [4] Create namespace_service_secrets indexes
    -- ========================================
    [4] = function()
        pcall(function() schema.create_index("namespace_service_secrets", "uuid") end)
        pcall(function() schema.create_index("namespace_service_secrets", "service_id") end)
        pcall(function() schema.create_index("namespace_service_secrets", "key") end)
    end,

    -- ========================================
    -- [5] Create namespace_service_deployments table
    -- Audit trail for all deployment triggers
    -- ========================================
    [5] = function()
        if table_exists("namespace_service_deployments") then return end

        -- Using raw SQL because Lapis doesn't support bigint type natively
        -- github_run_id needs to be bigint as GitHub run IDs can exceed integer range
        db.query([[
            CREATE TABLE namespace_service_deployments (
                id SERIAL PRIMARY KEY,
                uuid VARCHAR(255) NOT NULL UNIQUE,
                service_id INTEGER NOT NULL REFERENCES namespace_services(id) ON DELETE CASCADE,
                triggered_by INTEGER,

                -- GitHub Workflow Run Info
                github_run_id BIGINT,
                github_run_url VARCHAR(255),
                github_run_number INTEGER,

                -- Deployment Status
                status VARCHAR(255) NOT NULL DEFAULT 'pending',

                -- Non-secret inputs (JSON) - for audit purposes
                inputs TEXT NOT NULL DEFAULT '{}',

                -- Timing
                started_at TIMESTAMP WITHOUT TIME ZONE,
                completed_at TIMESTAMP WITHOUT TIME ZONE,

                -- Error handling
                error_message TEXT,
                error_details TEXT,

                -- Metadata
                created_at TIMESTAMP WITHOUT TIME ZONE,
                updated_at TIMESTAMP WITHOUT TIME ZONE
            )
        ]])

        -- Status constraint
        pcall(function()
            db.query([[
                ALTER TABLE namespace_service_deployments
                ADD CONSTRAINT namespace_service_deployments_status_check
                CHECK (status IN ('pending', 'triggered', 'running', 'success', 'failure', 'cancelled', 'error'))
            ]])
        end)

        -- Add foreign key for triggered_by
        add_foreign_key("namespace_service_deployments", "triggered_by", "users", "id",
            "namespace_service_deployments_user_fk", "SET NULL")
    end,

    -- ========================================
    -- [6] Create namespace_service_deployments indexes
    -- ========================================
    [6] = function()
        pcall(function() schema.create_index("namespace_service_deployments", "uuid") end)
        pcall(function() schema.create_index("namespace_service_deployments", "service_id") end)
        pcall(function() schema.create_index("namespace_service_deployments", "triggered_by") end)
        pcall(function() schema.create_index("namespace_service_deployments", "status") end)
        pcall(function() schema.create_index("namespace_service_deployments", "github_run_id") end)
        pcall(function() schema.create_index("namespace_service_deployments", "created_at") end)
    end,

    -- ========================================
    -- [7] Create namespace_service_variables table
    -- Non-secret workflow inputs/variables
    -- ========================================
    [7] = function()
        if table_exists("namespace_service_variables") then return end

        schema.create_table("namespace_service_variables", {
            { "id", types.serial },
            { "uuid", types.varchar({ unique = true }) },
            { "service_id", types.foreign_key },
            { "key", types.varchar },
            { "value", types.text },  -- Plain text, not encrypted
            { "description", types.text({ null = true }) },
            { "is_required", types.boolean({ default = false }) },
            { "default_value", types.text({ null = true }) },

            -- Metadata
            { "created_at", types.time({ null = true }) },
            { "updated_at", types.time({ null = true }) },

            "PRIMARY KEY (id)",
            "FOREIGN KEY (service_id) REFERENCES namespace_services(id) ON DELETE CASCADE"
        })

        -- Unique constraint on key within service
        pcall(function()
            db.query([[
                ALTER TABLE namespace_service_variables
                ADD CONSTRAINT namespace_service_variables_unique_key
                UNIQUE (service_id, key)
            ]])
        end)
    end,

    -- ========================================
    -- [8] Create namespace_service_variables indexes
    -- ========================================
    [8] = function()
        pcall(function() schema.create_index("namespace_service_variables", "uuid") end)
        pcall(function() schema.create_index("namespace_service_variables", "service_id") end)
        pcall(function() schema.create_index("namespace_service_variables", "key") end)
    end,

    -- ========================================
    -- [9] Add services permission to default namespace roles
    -- ========================================
    [9] = function()
        local cjson = require("cjson.safe")

        -- Get all namespace roles
        local roles = db.query([[
            SELECT id, permissions FROM namespace_roles
            WHERE role_name IN ('owner', 'admin', 'manager', 'member', 'viewer')
        ]])

        local role_permissions = {
            owner = { "create", "read", "update", "delete", "manage", "deploy" },
            admin = { "create", "read", "update", "delete", "deploy" },
            manager = { "read", "deploy" },
            member = { "read" },
            viewer = { "read" }
        }

        for _, role in ipairs(roles or {}) do
            local ok, perms = pcall(cjson.decode, role.permissions or "{}")
            if ok and type(perms) == "table" then
                -- Check role_name from a separate query
                local role_info = db.query("SELECT role_name FROM namespace_roles WHERE id = ?", role.id)
                if role_info and #role_info > 0 then
                    local role_name = role_info[1].role_name
                    if role_permissions[role_name] and not perms.services then
                        perms.services = role_permissions[role_name]
                        local new_perms = cjson.encode(perms)
                        db.update("namespace_roles", { permissions = new_perms }, { id = role.id })
                    end
                end
            end
        end
    end,

    -- ========================================
    -- [10] Create GitHub PAT storage table
    -- Stores encrypted GitHub Personal Access Tokens per namespace
    -- ========================================
    [10] = function()
        if table_exists("namespace_github_integrations") then return end

        schema.create_table("namespace_github_integrations", {
            { "id", types.serial },
            { "uuid", types.varchar({ unique = true }) },
            { "namespace_id", types.foreign_key },
            { "name", types.varchar({ default = "'default'" }) },
            { "github_token", types.text },  -- Encrypted PAT
            { "github_username", types.varchar({ null = true }) },
            { "status", types.varchar({ default = "'active'" }) },
            { "last_validated_at", types.time({ null = true }) },

            -- Metadata
            { "created_by", types.integer({ null = true }) },
            { "created_at", types.time({ null = true }) },
            { "updated_at", types.time({ null = true }) },

            "PRIMARY KEY (id)",
            "FOREIGN KEY (namespace_id) REFERENCES namespaces(id) ON DELETE CASCADE"
        })

        -- Unique name per namespace
        pcall(function()
            db.query([[
                ALTER TABLE namespace_github_integrations
                ADD CONSTRAINT namespace_github_integrations_unique_name
                UNIQUE (namespace_id, name)
            ]])
        end)
    end,

    -- ========================================
    -- [11] Create namespace_github_integrations indexes
    -- ========================================
    [11] = function()
        pcall(function() schema.create_index("namespace_github_integrations", "uuid") end)
        pcall(function() schema.create_index("namespace_github_integrations", "namespace_id") end)
        pcall(function() schema.create_index("namespace_github_integrations", "status") end)
    end,

    -- ========================================
    -- [12] Add github_integration_id to namespace_services
    -- ========================================
    [12] = function()
        if not table_exists("namespace_services") then return end
        if column_exists("namespace_services", "github_integration_id") then return end

        schema.add_column("namespace_services", "github_integration_id", types.integer({ null = true }))
        add_foreign_key("namespace_services", "github_integration_id", "namespace_github_integrations", "id",
            "namespace_services_github_integration_fk", "SET NULL")
        pcall(function() schema.create_index("namespace_services", "github_integration_id") end)
    end,
}
