--[[
    Multi-Tenant Namespace System Migrations

    Architecture: USER-FIRST
    =========================
    - Users are GLOBAL entities (exist independently of namespaces)
    - Users register globally, then create or join namespaces
    - A user can belong to multiple namespaces
    - Each namespace has its own roles, permissions, and data

    Tables:
    - namespaces: Core tenant entities (companies/organizations)
    - namespace_members: User-namespace membership (many-to-many)
    - namespace_roles: Roles scoped to each namespace
    - namespace_user_roles: User's role within a namespace
    - namespace_invitations: Pending invitations
    - user_namespace_settings: User preferences per namespace (e.g., default namespace)

    Also modifies existing tables to add namespace_id for tenant isolation.
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
    -- [1] Create namespaces table
    -- ========================================
    [1] = function()
        if table_exists("namespaces") then return end

        schema.create_table("namespaces", {
            { "id", types.serial },
            { "uuid", types.varchar({ unique = true }) },
            { "name", types.varchar },
            { "slug", types.varchar({ unique = true }) },
            { "description", types.text({ null = true }) },
            { "domain", types.varchar({ null = true, unique = true }) },
            { "logo_url", types.varchar({ null = true }) },
            { "banner_url", types.varchar({ null = true }) },
            { "status", types.varchar({ default = "'active'" }) },
            { "plan", types.varchar({ default = "'free'" }) },
            { "settings", types.text({ default = "'{}'" }) },
            { "max_users", types.integer({ default = 10 }) },
            { "max_stores", types.integer({ default = 5 }) },
            { "owner_user_id", types.integer({ null = true }) },
            { "created_at", types.time({ null = true }) },
            { "updated_at", types.time({ null = true }) },
            "PRIMARY KEY (id)"
        })

        -- Status constraint
        pcall(function()
            db.query([[
                ALTER TABLE namespaces
                ADD CONSTRAINT namespaces_status_check
                CHECK (status IN ('active', 'suspended', 'pending', 'archived'))
            ]])
        end)

        -- Plan constraint
        pcall(function()
            db.query([[
                ALTER TABLE namespaces
                ADD CONSTRAINT namespaces_plan_check
                CHECK (plan IN ('free', 'starter', 'professional', 'enterprise'))
            ]])
        end)

        -- Slug format constraint (lowercase alphanumeric with hyphens)
        pcall(function()
            db.query([[
                ALTER TABLE namespaces
                ADD CONSTRAINT namespaces_slug_format
                CHECK (slug ~ '^[a-z0-9][a-z0-9\-]*[a-z0-9]$' OR LENGTH(slug) = 1)
            ]])
        end)
    end,

    -- ========================================
    -- [2] Create namespaces indexes
    -- ========================================
    [2] = function()
        pcall(function() schema.create_index("namespaces", "slug") end)
        pcall(function() schema.create_index("namespaces", "status") end)
        pcall(function() schema.create_index("namespaces", "owner_user_id") end)
        pcall(function() schema.create_index("namespaces", "domain") end)
        pcall(function() schema.create_index("namespaces", "plan") end)
        pcall(function() schema.create_index("namespaces", "created_at") end)
    end,

    -- ========================================
    -- [3] Create namespace_members table
    -- Links global users to namespaces (many-to-many)
    -- ========================================
    [3] = function()
        if table_exists("namespace_members") then return end

        schema.create_table("namespace_members", {
            { "id", types.serial },
            { "uuid", types.varchar({ unique = true }) },
            { "namespace_id", types.foreign_key },
            { "user_id", types.foreign_key },
            { "status", types.varchar({ default = "'active'" }) },
            { "is_owner", types.boolean({ default = false }) },
            { "joined_at", types.time({ null = true }) },
            { "invited_by", types.integer({ null = true }) },
            { "created_at", types.time({ null = true }) },
            { "updated_at", types.time({ null = true }) },
            "PRIMARY KEY (id)",
            "FOREIGN KEY (namespace_id) REFERENCES namespaces(id) ON DELETE CASCADE",
            "FOREIGN KEY (user_id) REFERENCES users(id) ON DELETE CASCADE",
            "UNIQUE (namespace_id, user_id)"
        })

        pcall(function()
            db.query([[
                ALTER TABLE namespace_members
                ADD CONSTRAINT namespace_members_status_check
                CHECK (status IN ('active', 'invited', 'suspended', 'left'))
            ]])
        end)
    end,

    -- ========================================
    -- [4] Create namespace_members indexes
    -- ========================================
    [4] = function()
        pcall(function() schema.create_index("namespace_members", "namespace_id") end)
        pcall(function() schema.create_index("namespace_members", "user_id") end)
        pcall(function() schema.create_index("namespace_members", "status") end)
        pcall(function() schema.create_index("namespace_members", "is_owner") end)
        pcall(function() schema.create_index("namespace_members", "joined_at") end)
    end,

    -- ========================================
    -- [5] Create namespace_roles table
    -- Roles are scoped per namespace
    -- ========================================
    [5] = function()
        if table_exists("namespace_roles") then return end

        schema.create_table("namespace_roles", {
            { "id", types.serial },
            { "uuid", types.varchar({ unique = true }) },
            { "namespace_id", types.foreign_key },
            { "role_name", types.varchar },
            { "display_name", types.varchar({ null = true }) },
            { "description", types.text({ null = true }) },
            { "permissions", types.text({ default = "'{}'" }) },
            { "is_system", types.boolean({ default = false }) },
            { "is_default", types.boolean({ default = false }) },
            { "priority", types.integer({ default = 0 }) },
            { "created_at", types.time({ null = true }) },
            { "updated_at", types.time({ null = true }) },
            "PRIMARY KEY (id)",
            "FOREIGN KEY (namespace_id) REFERENCES namespaces(id) ON DELETE CASCADE",
            "UNIQUE (namespace_id, role_name)"
        })
    end,

    -- ========================================
    -- [6] Create namespace_roles indexes
    -- ========================================
    [6] = function()
        pcall(function() schema.create_index("namespace_roles", "namespace_id") end)
        pcall(function() schema.create_index("namespace_roles", "role_name") end)
        pcall(function() schema.create_index("namespace_roles", "is_default") end)
        pcall(function() schema.create_index("namespace_roles", "is_system") end)
        pcall(function() schema.create_index("namespace_roles", "priority") end)
    end,

    -- ========================================
    -- [7] Create namespace_user_roles table
    -- Assigns roles to namespace members
    -- ========================================
    [7] = function()
        if table_exists("namespace_user_roles") then return end

        schema.create_table("namespace_user_roles", {
            { "id", types.serial },
            { "uuid", types.varchar({ unique = true }) },
            { "namespace_member_id", types.foreign_key },
            { "namespace_role_id", types.foreign_key },
            { "created_at", types.time({ null = true }) },
            { "updated_at", types.time({ null = true }) },
            "PRIMARY KEY (id)",
            "FOREIGN KEY (namespace_member_id) REFERENCES namespace_members(id) ON DELETE CASCADE",
            "FOREIGN KEY (namespace_role_id) REFERENCES namespace_roles(id) ON DELETE CASCADE",
            "UNIQUE (namespace_member_id, namespace_role_id)"
        })
    end,

    -- ========================================
    -- [8] Create namespace_user_roles indexes
    -- ========================================
    [8] = function()
        pcall(function() schema.create_index("namespace_user_roles", "namespace_member_id") end)
        pcall(function() schema.create_index("namespace_user_roles", "namespace_role_id") end)
    end,

    -- ========================================
    -- [9] Create namespace_invitations table
    -- ========================================
    [9] = function()
        if table_exists("namespace_invitations") then return end

        schema.create_table("namespace_invitations", {
            { "id", types.serial },
            { "uuid", types.varchar({ unique = true }) },
            { "namespace_id", types.foreign_key },
            { "email", types.varchar },
            { "role_id", types.integer({ null = true }) },
            { "token", types.varchar({ unique = true }) },
            { "status", types.varchar({ default = "'pending'" }) },
            { "message", types.text({ null = true }) },
            { "invited_by", types.foreign_key },
            { "expires_at", types.time },
            { "accepted_at", types.time({ null = true }) },
            { "created_at", types.time({ null = true }) },
            { "updated_at", types.time({ null = true }) },
            "PRIMARY KEY (id)",
            "FOREIGN KEY (namespace_id) REFERENCES namespaces(id) ON DELETE CASCADE",
            "FOREIGN KEY (invited_by) REFERENCES users(id) ON DELETE CASCADE"
        })

        pcall(function()
            db.query([[
                ALTER TABLE namespace_invitations
                ADD CONSTRAINT namespace_invitations_status_check
                CHECK (status IN ('pending', 'accepted', 'expired', 'revoked'))
            ]])
        end)
    end,

    -- ========================================
    -- [10] Create namespace_invitations indexes
    -- ========================================
    [10] = function()
        pcall(function() schema.create_index("namespace_invitations", "namespace_id") end)
        pcall(function() schema.create_index("namespace_invitations", "email") end)
        pcall(function() schema.create_index("namespace_invitations", "token") end)
        pcall(function() schema.create_index("namespace_invitations", "status") end)
        pcall(function() schema.create_index("namespace_invitations", "expires_at") end)
        pcall(function() schema.create_index("namespace_invitations", "invited_by") end)
    end,

    -- ========================================
    -- [11] Create user_namespace_settings table
    -- Stores user preferences (e.g., default namespace)
    -- ========================================
    [11] = function()
        if table_exists("user_namespace_settings") then return end

        schema.create_table("user_namespace_settings", {
            { "id", types.serial },
            { "user_id", types.foreign_key },
            { "default_namespace_id", types.integer({ null = true }) },
            { "last_active_namespace_id", types.integer({ null = true }) },
            { "created_at", types.time({ null = true }) },
            { "updated_at", types.time({ null = true }) },
            "PRIMARY KEY (id)",
            "FOREIGN KEY (user_id) REFERENCES users(id) ON DELETE CASCADE",
            "UNIQUE (user_id)"
        })

        add_foreign_key("user_namespace_settings", "default_namespace_id", "namespaces", "id", "user_ns_settings_default_fk", "SET NULL")
        add_foreign_key("user_namespace_settings", "last_active_namespace_id", "namespaces", "id", "user_ns_settings_last_active_fk", "SET NULL")
    end,

    -- ========================================
    -- [12] Create user_namespace_settings indexes
    -- ========================================
    [12] = function()
        pcall(function() schema.create_index("user_namespace_settings", "user_id") end)
        pcall(function() schema.create_index("user_namespace_settings", "default_namespace_id") end)
        pcall(function() schema.create_index("user_namespace_settings", "last_active_namespace_id") end)
    end,

    -- ========================================
    -- [13-21] Add namespace_id to tenant tables
    -- ========================================
    [13] = function()
        if not table_exists("stores") then return end
        if column_exists("stores", "namespace_id") then return end

        schema.add_column("stores", "namespace_id", types.integer({ null = true }))
        add_foreign_key("stores", "namespace_id", "namespaces", "id", "stores_namespace_fk", "CASCADE")
        pcall(function() schema.create_index("stores", "namespace_id") end)
    end,

    [14] = function()
        if not table_exists("orders") then return end
        if column_exists("orders", "namespace_id") then return end

        schema.add_column("orders", "namespace_id", types.integer({ null = true }))
        add_foreign_key("orders", "namespace_id", "namespaces", "id", "orders_namespace_fk", "CASCADE")
        pcall(function() schema.create_index("orders", "namespace_id") end)
    end,

    [15] = function()
        if not table_exists("customers") then return end
        if column_exists("customers", "namespace_id") then return end

        schema.add_column("customers", "namespace_id", types.integer({ null = true }))
        add_foreign_key("customers", "namespace_id", "namespaces", "id", "customers_namespace_fk", "CASCADE")
        pcall(function() schema.create_index("customers", "namespace_id") end)
    end,

    [16] = function()
        if not table_exists("categories") then return end
        if column_exists("categories", "namespace_id") then return end

        schema.add_column("categories", "namespace_id", types.integer({ null = true }))
        add_foreign_key("categories", "namespace_id", "namespaces", "id", "categories_namespace_fk", "CASCADE")
        pcall(function() schema.create_index("categories", "namespace_id") end)
    end,

    [17] = function()
        if not table_exists("storeproducts") then return end
        if column_exists("storeproducts", "namespace_id") then return end

        schema.add_column("storeproducts", "namespace_id", types.integer({ null = true }))
        add_foreign_key("storeproducts", "namespace_id", "namespaces", "id", "storeproducts_namespace_fk", "CASCADE")
        pcall(function() schema.create_index("storeproducts", "namespace_id") end)
    end,

    [18] = function()
        if not table_exists("chat_channels") then return end
        if column_exists("chat_channels", "namespace_id") then return end

        schema.add_column("chat_channels", "namespace_id", types.integer({ null = true }))
        add_foreign_key("chat_channels", "namespace_id", "namespaces", "id", "chat_channels_namespace_fk", "CASCADE")
        pcall(function() schema.create_index("chat_channels", "namespace_id") end)
    end,

    [19] = function()
        if not table_exists("delivery_partners") then return end
        if column_exists("delivery_partners", "namespace_id") then return end

        schema.add_column("delivery_partners", "namespace_id", types.integer({ null = true }))
        add_foreign_key("delivery_partners", "namespace_id", "namespaces", "id", "delivery_partners_namespace_fk", "CASCADE")
        pcall(function() schema.create_index("delivery_partners", "namespace_id") end)
    end,

    [20] = function()
        if not table_exists("notifications") then return end
        if column_exists("notifications", "namespace_id") then return end

        schema.add_column("notifications", "namespace_id", types.integer({ null = true }))
        add_foreign_key("notifications", "namespace_id", "namespaces", "id", "notifications_namespace_fk", "CASCADE")
        pcall(function() schema.create_index("notifications", "namespace_id") end)
    end,

    [21] = function()
        if not table_exists("enquiries") then return end
        if column_exists("enquiries", "namespace_id") then return end

        schema.add_column("enquiries", "namespace_id", types.integer({ null = true }))
        add_foreign_key("enquiries", "namespace_id", "namespaces", "id", "enquiries_namespace_fk", "CASCADE")
        pcall(function() schema.create_index("enquiries", "namespace_id") end)
    end,

    -- ========================================
    -- [22] Seed default "System" namespace with roles
    -- ========================================
    [22] = function()
        local MigrationUtils = require("helper.migration-utils")
        local timestamp = MigrationUtils.getCurrentTimestamp()

        -- Check if default namespace exists
        local existing = db.select("* FROM namespaces WHERE slug = ?", "system")
        if #existing > 0 then return end

        -- Create default namespace
        local namespace_uuid = MigrationUtils.generateUUID()
        db.insert("namespaces", {
            uuid = namespace_uuid,
            name = "System",
            slug = "system",
            description = "Default system namespace for platform administration",
            status = "active",
            plan = "enterprise",
            settings = "{}",
            max_users = 1000000,
            max_stores = 1000000,
            created_at = timestamp,
            updated_at = timestamp
        })

        -- Get the namespace ID
        local namespace = db.select("* FROM namespaces WHERE slug = ?", "system")
        local namespace_id = namespace[1].id

        -- Create default roles
        local default_roles = {
            {
                role_name = "owner",
                display_name = "Owner",
                description = "Full control over the namespace including deletion",
                permissions = '{"dashboard":["create","read","update","delete","manage"],"users":["create","read","update","delete","manage"],"roles":["create","read","update","delete","manage"],"stores":["create","read","update","delete","manage"],"products":["create","read","update","delete","manage"],"orders":["create","read","update","delete","manage"],"customers":["create","read","update","delete","manage"],"settings":["create","read","update","delete","manage"],"namespace":["create","read","update","delete","manage"],"chat":["create","read","update","delete","manage"],"delivery":["create","read","update","delete","manage"],"reports":["create","read","update","delete","manage"]}',
                is_system = true,
                is_default = false,
                priority = 100
            },
            {
                role_name = "admin",
                display_name = "Administrator",
                description = "Full administrative access except namespace deletion",
                permissions = '{"dashboard":["create","read","update","delete","manage"],"users":["create","read","update","delete"],"roles":["create","read","update","delete"],"stores":["create","read","update","delete","manage"],"products":["create","read","update","delete","manage"],"orders":["create","read","update","delete","manage"],"customers":["create","read","update","delete","manage"],"settings":["create","read","update","delete"],"namespace":["read","update"],"chat":["create","read","update","delete","manage"],"delivery":["create","read","update","delete","manage"],"reports":["read","manage"]}',
                is_system = true,
                is_default = false,
                priority = 90
            },
            {
                role_name = "manager",
                display_name = "Manager",
                description = "Manage daily operations and team",
                permissions = '{"dashboard":["read"],"users":["read"],"roles":["read"],"stores":["create","read","update"],"products":["create","read","update","delete"],"orders":["create","read","update"],"customers":["create","read","update"],"settings":["read"],"namespace":["read"],"chat":["create","read","update"],"delivery":["read","update"],"reports":["read"]}',
                is_system = true,
                is_default = false,
                priority = 50
            },
            {
                role_name = "member",
                display_name = "Member",
                description = "Standard member with limited access",
                permissions = '{"dashboard":["read"],"stores":["read"],"products":["read"],"orders":["read"],"customers":["read"],"chat":["read"]}',
                is_system = true,
                is_default = true,
                priority = 20
            },
            {
                role_name = "viewer",
                display_name = "Viewer",
                description = "Read-only access to basic information",
                permissions = '{"dashboard":["read"],"stores":["read"],"products":["read"],"orders":["read"]}',
                is_system = true,
                is_default = false,
                priority = 10
            }
        }

        for _, role in ipairs(default_roles) do
            db.insert("namespace_roles", {
                uuid = MigrationUtils.generateUUID(),
                namespace_id = namespace_id,
                role_name = role.role_name,
                display_name = role.display_name,
                description = role.description,
                permissions = role.permissions,
                is_system = role.is_system,
                is_default = role.is_default,
                priority = role.priority,
                created_at = timestamp,
                updated_at = timestamp
            })
        end
    end,

    -- ========================================
    -- [23] Add admin user to system namespace as owner
    -- ========================================
    [23] = function()
        local MigrationUtils = require("helper.migration-utils")
        local timestamp = MigrationUtils.getCurrentTimestamp()

        local namespace = db.select("* FROM namespaces WHERE slug = ?", "system")
        if #namespace == 0 then return end
        local namespace_id = namespace[1].id

        -- Find admin user
        local admin_user = db.select("* FROM users WHERE username = ?", "administrative")
        if #admin_user == 0 then return end
        local user_id = admin_user[1].id

        -- Check if already a member
        local existing_member = db.select("* FROM namespace_members WHERE namespace_id = ? AND user_id = ?", namespace_id, user_id)
        if #existing_member > 0 then return end

        -- Add as owner
        local member_uuid = MigrationUtils.generateUUID()
        db.insert("namespace_members", {
            uuid = member_uuid,
            namespace_id = namespace_id,
            user_id = user_id,
            status = "active",
            is_owner = true,
            joined_at = timestamp,
            created_at = timestamp,
            updated_at = timestamp
        })

        -- Get member ID
        local member = db.select("* FROM namespace_members WHERE uuid = ?", member_uuid)
        if #member == 0 then return end

        -- Assign owner role
        local owner_role = db.select("* FROM namespace_roles WHERE namespace_id = ? AND role_name = ?", namespace_id, "owner")
        if #owner_role > 0 then
            db.insert("namespace_user_roles", {
                uuid = MigrationUtils.generateUUID(),
                namespace_member_id = member[1].id,
                namespace_role_id = owner_role[1].id,
                created_at = timestamp,
                updated_at = timestamp
            })
        end

        -- Update namespace owner
        db.update("namespaces", { owner_user_id = user_id }, { id = namespace_id })

        -- Set as user's default namespace
        if table_exists("user_namespace_settings") then
            local existing_settings = db.select("* FROM user_namespace_settings WHERE user_id = ?", user_id)
            if #existing_settings == 0 then
                db.insert("user_namespace_settings", {
                    user_id = user_id,
                    default_namespace_id = namespace_id,
                    last_active_namespace_id = namespace_id,
                    created_at = timestamp,
                    updated_at = timestamp
                })
            end
        end
    end,

    -- ========================================
    -- [24] Migrate existing data to system namespace
    -- ========================================
    [24] = function()
        local namespace = db.select("* FROM namespaces WHERE slug = ?", "system")
        if #namespace == 0 then return end
        local namespace_id = namespace[1].id

        local tables = {
            "stores", "orders", "customers", "categories", "storeproducts",
            "chat_channels", "delivery_partners", "notifications", "enquiries"
        }

        for _, tbl_name in ipairs(tables) do
            if table_exists(tbl_name) and column_exists(tbl_name, "namespace_id") then
                pcall(function()
                    db.query("UPDATE " .. tbl_name .. " SET namespace_id = ? WHERE namespace_id IS NULL", namespace_id)
                end)
            end
        end
    end,

    -- ========================================
    -- [25] Add all existing users to system namespace
    -- ========================================
    [25] = function()
        local MigrationUtils = require("helper.migration-utils")
        local timestamp = MigrationUtils.getCurrentTimestamp()

        local namespace = db.select("* FROM namespaces WHERE slug = ?", "system")
        if #namespace == 0 then return end
        local namespace_id = namespace[1].id

        -- Get member role
        local member_role = db.select("* FROM namespace_roles WHERE namespace_id = ? AND role_name = ?", namespace_id, "member")
        if #member_role == 0 then return end
        local role_id = member_role[1].id

        -- Get all users not yet in this namespace
        local users = db.query([[
            SELECT u.* FROM users u
            LEFT JOIN namespace_members nm ON u.id = nm.user_id AND nm.namespace_id = ?
            WHERE nm.id IS NULL
        ]], namespace_id)

        for _, user in ipairs(users or {}) do
            local member_uuid = MigrationUtils.generateUUID()

            -- Add to namespace
            db.insert("namespace_members", {
                uuid = member_uuid,
                namespace_id = namespace_id,
                user_id = user.id,
                status = "active",
                is_owner = false,
                joined_at = timestamp,
                created_at = timestamp,
                updated_at = timestamp
            })

            -- Get member ID and assign role
            local member = db.select("* FROM namespace_members WHERE uuid = ?", member_uuid)
            if #member > 0 then
                db.insert("namespace_user_roles", {
                    uuid = MigrationUtils.generateUUID(),
                    namespace_member_id = member[1].id,
                    namespace_role_id = role_id,
                    created_at = timestamp,
                    updated_at = timestamp
                })
            end

            -- Set as default namespace if user doesn't have one
            if table_exists("user_namespace_settings") then
                local existing_settings = db.select("* FROM user_namespace_settings WHERE user_id = ?", user.id)
                if #existing_settings == 0 then
                    db.insert("user_namespace_settings", {
                        user_id = user.id,
                        default_namespace_id = namespace_id,
                        last_active_namespace_id = namespace_id,
                        created_at = timestamp,
                        updated_at = timestamp
                    })
                end
            end
        end
    end,

    -- ========================================
    -- [26] Create namespace_audit_logs table
    -- ========================================
    [26] = function()
        if table_exists("namespace_audit_logs") then return end

        schema.create_table("namespace_audit_logs", {
            { "id", types.serial },
            { "uuid", types.varchar({ unique = true }) },
            { "namespace_id", types.foreign_key },
            { "user_id", types.integer({ null = true }) },
            { "action", types.varchar },
            { "entity_type", types.varchar },
            { "entity_id", types.varchar({ null = true }) },
            { "old_values", types.text({ null = true }) },
            { "new_values", types.text({ null = true }) },
            { "ip_address", types.varchar({ null = true }) },
            { "user_agent", types.text({ null = true }) },
            { "created_at", types.time({ null = true }) },
            "PRIMARY KEY (id)",
            "FOREIGN KEY (namespace_id) REFERENCES namespaces(id) ON DELETE CASCADE"
        })
    end,

    -- ========================================
    -- [27] Create namespace_audit_logs indexes
    -- ========================================
    [27] = function()
        pcall(function() schema.create_index("namespace_audit_logs", "namespace_id") end)
        pcall(function() schema.create_index("namespace_audit_logs", "user_id") end)
        pcall(function() schema.create_index("namespace_audit_logs", "action") end)
        pcall(function() schema.create_index("namespace_audit_logs", "entity_type") end)
        pcall(function() schema.create_index("namespace_audit_logs", "created_at") end)
    end,

    -- ========================================
    -- [28] Ensure namespace_id on all tables (catch-all for fresh installs)
    -- ========================================
    [28] = function()
        local tables_config = {
            { name = "stores", constraint = "stores_namespace_fk" },
            { name = "orders", constraint = "orders_namespace_fk" },
            { name = "customers", constraint = "customers_namespace_fk" },
            { name = "categories", constraint = "categories_namespace_fk" },
            { name = "storeproducts", constraint = "storeproducts_namespace_fk" },
            { name = "chat_channels", constraint = "chat_channels_namespace_fk" },
            { name = "delivery_partners", constraint = "delivery_partners_namespace_fk" },
            { name = "notifications", constraint = "notifications_namespace_fk" },
            { name = "enquiries", constraint = "enquiries_namespace_fk" }
        }

        local namespace = db.select("* FROM namespaces WHERE slug = ?", "system")
        local namespace_id = #namespace > 0 and namespace[1].id or nil

        for _, tbl in ipairs(tables_config) do
            if table_exists(tbl.name) and not column_exists(tbl.name, "namespace_id") then
                schema.add_column(tbl.name, "namespace_id", types.integer({ null = true }))
                add_foreign_key(tbl.name, "namespace_id", "namespaces", "id", tbl.constraint, "CASCADE")
                pcall(function() schema.create_index(tbl.name, "namespace_id") end)

                if namespace_id then
                    pcall(function()
                        db.query("UPDATE " .. tbl.name .. " SET namespace_id = ? WHERE namespace_id IS NULL", namespace_id)
                    end)
                end
            end
        end
    end,
}
