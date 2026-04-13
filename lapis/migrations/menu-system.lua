--[[
    Backend-Driven Menu System (Multi-Tenant)

    This migration creates a namespace-aware menu system:
    - menu_items: Global menu template (defines all available menu items)
    - namespace_menu_config: Per-namespace menu customization (enable/disable, reorder)

    Architecture:
    - Menu items are defined globally as templates
    - Each namespace can customize which menus are enabled and their order
    - When a user requests the menu, we filter based on:
      1. Namespace's enabled menus
      2. User's permissions within that namespace
    - This ensures consistent permission checking across all clients (web, mobile, API)

    Multi-Tenant Design:
    - Users can have different roles in different namespaces
    - Each namespace can customize its own menu configuration
    - Menu filtering happens based on user's permissions in the CURRENT namespace context
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

return {
    -- ========================================
    -- [1] Create menu_items table (Global Menu Template)
    -- ========================================
    [1] = function()
        if table_exists("menu_items") then return end

        schema.create_table("menu_items", {
            { "id", types.serial },
            { "uuid", types.varchar({ unique = true }) },
            { "name", types.varchar },                      -- Display name
            { "key", types.varchar({ unique = true }) },    -- Unique identifier (e.g., "dashboard", "users")
            { "icon", types.varchar({ null = true }) },     -- Icon name for UI
            { "path", types.varchar },                      -- URL path (e.g., "/dashboard", "/dashboard/users")
            { "module", types.varchar({ null = true }) },   -- Permission module to check (nullable for always-visible items)
            { "required_action", types.varchar({ default = "'read'" }) }, -- Required permission action
            { "parent_id", types.integer({ null = true, default = db.NULL }) }, -- For nested menus
            { "priority", types.integer({ default = 0 }) }, -- Display order
            { "is_active", types.boolean({ default = true }) }, -- Can be disabled globally
            { "is_admin_only", types.boolean({ default = false }) }, -- Platform admin only
            { "always_show", types.boolean({ default = false }) }, -- Always show regardless of permissions (e.g., My Workspace)
            { "badge_key", types.varchar({ null = true }) }, -- Key for dynamic badge counts
            { "settings", types.text({ default = "'{}'" }) }, -- Additional settings as JSON
            { "created_at", types.time({ null = true }) },
            { "updated_at", types.time({ null = true }) },
            "PRIMARY KEY (id)"
        })

        -- Self-referencing foreign key for parent
        pcall(function()
            db.query([[
                ALTER TABLE menu_items
                ADD CONSTRAINT menu_items_parent_fk
                FOREIGN KEY (parent_id) REFERENCES menu_items(id) ON DELETE SET NULL
            ]])
        end)
    end,

    -- ========================================
    -- [2] Create menu_items indexes
    -- ========================================
    [2] = function()
        pcall(function() schema.create_index("menu_items", "key") end)
        pcall(function() schema.create_index("menu_items", "module") end)
        pcall(function() schema.create_index("menu_items", "parent_id") end)
        pcall(function() schema.create_index("menu_items", "priority") end)
        pcall(function() schema.create_index("menu_items", "is_active") end)
        pcall(function() schema.create_index("menu_items", "is_admin_only") end)
    end,

    -- ========================================
    -- [3] Create namespace_menu_config table (Per-Namespace Customization)
    -- ========================================
    [3] = function()
        if table_exists("namespace_menu_config") then return end

        schema.create_table("namespace_menu_config", {
            { "id", types.serial },
            { "uuid", types.varchar({ unique = true }) },
            { "namespace_id", types.foreign_key },
            { "menu_item_id", types.foreign_key },
            { "is_enabled", types.boolean({ default = true }) }, -- Enable/disable for this namespace
            { "custom_name", types.varchar({ null = true }) },   -- Override display name
            { "custom_icon", types.varchar({ null = true }) },   -- Override icon
            { "custom_priority", types.integer({ null = true, default = db.NULL }) }, -- Override display order
            { "settings", types.text({ default = "'{}'" }) },    -- Namespace-specific settings
            { "created_at", types.time({ null = true }) },
            { "updated_at", types.time({ null = true }) },
            "PRIMARY KEY (id)",
            "FOREIGN KEY (namespace_id) REFERENCES namespaces(id) ON DELETE CASCADE",
            "FOREIGN KEY (menu_item_id) REFERENCES menu_items(id) ON DELETE CASCADE",
            "UNIQUE (namespace_id, menu_item_id)"
        })
    end,

    -- ========================================
    -- [4] Create namespace_menu_config indexes
    -- ========================================
    [4] = function()
        pcall(function() schema.create_index("namespace_menu_config", "namespace_id") end)
        pcall(function() schema.create_index("namespace_menu_config", "menu_item_id") end)
        pcall(function() schema.create_index("namespace_menu_config", "is_enabled") end)
    end,

    -- ========================================
    -- [5] Seed default menu items (Global Template)
    -- ========================================
    [5] = function()
        local MigrationUtils = require("helper.migration-utils")
        local timestamp = MigrationUtils.getCurrentTimestamp()

        -- Check if already seeded
        local existing = db.select("* FROM menu_items WHERE key = ?", "dashboard")
        if #existing > 0 then return end

        -- Main navigation menu items (Global template)
        local menu_items = {
            {
                key = "dashboard",
                name = "Dashboard",
                icon = "LayoutDashboard",
                path = "/dashboard",
                module = "dashboard",
                required_action = "read",
                priority = 1,
                always_show = false
            },
            {
                key = "namespace",
                name = "My Workspace",
                icon = "Building2",
                path = "/dashboard/namespace",
                module = "namespace",
                required_action = "read",
                priority = 2,
                always_show = true  -- Always visible for any authenticated user in namespace
            },
            {
                key = "namespaces",
                name = "All Namespaces",
                icon = "Building2",
                path = "/dashboard/namespaces",
                module = "namespaces",
                required_action = "read",
                priority = 3,
                is_admin_only = true  -- Platform admin only (global admin, not namespace admin)
            },
            {
                key = "projects",
                name = "Projects",
                icon = "Kanban",
                path = "/dashboard/projects",
                module = "projects",
                required_action = "read",
                priority = 4,
                always_show = false
            },
            {
                key = "services",
                name = "Services",
                icon = "Rocket",
                path = "/dashboard/services",
                module = "services",
                required_action = "read",
                priority = 5,
                always_show = false
            },
            {
                key = "users",
                name = "Users",
                icon = "Users",
                path = "/dashboard/users",
                module = "users",
                required_action = "read",
                priority = 6,
                always_show = false
            },
            {
                key = "roles",
                name = "Roles",
                icon = "Shield",
                path = "/dashboard/roles",
                module = "roles",
                required_action = "read",
                priority = 7,
                always_show = false
            },
            {
                key = "orders",
                name = "Orders",
                icon = "ShoppingCart",
                path = "/dashboard/orders",
                module = "orders",
                required_action = "read",
                priority = 8,
                always_show = false
            },
            {
                key = "products",
                name = "Products",
                icon = "Package",
                path = "/dashboard/products",
                module = "products",
                required_action = "read",
                priority = 9,
                always_show = false
            },
            {
                key = "stores",
                name = "Stores",
                icon = "Store",
                path = "/dashboard/stores",
                module = "stores",
                required_action = "read",
                priority = 10,
                always_show = false
            },
            {
                key = "customers",
                name = "Customers",
                icon = "UserCircle",
                path = "/dashboard/customers",
                module = "customers",
                required_action = "read",
                priority = 11,
                always_show = false
            },
            {
                key = "delivery",
                name = "Delivery",
                icon = "Truck",
                path = "/dashboard/delivery",
                module = "delivery",
                required_action = "read",
                priority = 12,
                always_show = false
            },
            {
                key = "chat",
                name = "Chat",
                icon = "MessageSquare",
                path = "/dashboard/chat",
                module = "chat",
                required_action = "read",
                priority = 13,
                always_show = false
            },
            {
                key = "reports",
                name = "Reports",
                icon = "BarChart3",
                path = "/dashboard/reports",
                module = "reports",
                required_action = "read",
                priority = 14,
                always_show = false
            },
            -- Secondary navigation
            {
                key = "settings",
                name = "Settings",
                icon = "Settings",
                path = "/dashboard/settings",
                module = "settings",
                required_action = "read",
                priority = 100,  -- Higher priority = shown at bottom/secondary section
                always_show = false
            }
        }

        for _, item in ipairs(menu_items) do
            db.insert("menu_items", {
                uuid = MigrationUtils.generateUUID(),
                key = item.key,
                name = item.name,
                icon = item.icon,
                path = item.path,
                module = item.module,
                required_action = item.required_action or "read",
                priority = item.priority,
                is_active = true,
                is_admin_only = item.is_admin_only or false,
                always_show = item.always_show or false,
                settings = "{}",
                created_at = timestamp,
                updated_at = timestamp
            })
        end
    end,

    -- ========================================
    -- [6] Add services and projects modules to existing modules table
    -- ========================================
    [6] = function()
        local MigrationUtils = require("helper.migration-utils")
        local timestamp = MigrationUtils.getCurrentTimestamp()

        local new_modules = {
            { machine_name = "services", name = "Services", description = "Service management and deployment", priority = 10 },
            { machine_name = "delivery", name = "Delivery", description = "Delivery management and tracking", priority = 11 },
            { machine_name = "chat", name = "Chat", description = "Chat and messaging features", priority = 12 },
            { machine_name = "reports", name = "Reports", description = "Reports and analytics", priority = 13 },
            { machine_name = "projects", name = "Projects", description = "Project and kanban board management", priority = 14 },
            { machine_name = "namespace", name = "Namespace", description = "Current namespace workspace", priority = 15 }
        }

        for _, mod in ipairs(new_modules) do
            local existing = db.select("* FROM modules WHERE machine_name = ?", mod.machine_name)
            if #existing == 0 then
                db.insert("modules", {
                    uuid = MigrationUtils.generateUUID(),
                    machine_name = mod.machine_name,
                    name = mod.name,
                    description = mod.description,
                    priority = mod.priority,
                    created_at = timestamp,
                    updated_at = timestamp
                })
            end
        end
    end,

    -- ========================================
    -- [7] Update namespace_roles default permissions to include new modules
    -- ========================================
    [7] = function()
        -- Update existing default roles to include services, delivery, chat, reports, projects
        -- This updates the system namespace's default roles

        local namespace = db.select("* FROM namespaces WHERE slug = ?", "system")
        if #namespace == 0 then return end
        local namespace_id = namespace[1].id

        -- Update owner role - full access to all modules
        local owner_permissions = '{"dashboard":["create","read","update","delete","manage"],"users":["create","read","update","delete","manage"],"roles":["create","read","update","delete","manage"],"stores":["create","read","update","delete","manage"],"products":["create","read","update","delete","manage"],"orders":["create","read","update","delete","manage"],"customers":["create","read","update","delete","manage"],"settings":["create","read","update","delete","manage"],"namespace":["create","read","update","delete","manage"],"chat":["create","read","update","delete","manage"],"delivery":["create","read","update","delete","manage"],"reports":["create","read","update","delete","manage"],"services":["create","read","update","delete","manage","deploy"],"projects":["create","read","update","delete","manage"]}'

        db.update("namespace_roles", {
            permissions = owner_permissions
        }, {
            namespace_id = namespace_id,
            role_name = "owner"
        })

        -- Update admin role
        local admin_permissions = '{"dashboard":["create","read","update","delete","manage"],"users":["create","read","update","delete"],"roles":["create","read","update","delete"],"stores":["create","read","update","delete","manage"],"products":["create","read","update","delete","manage"],"orders":["create","read","update","delete","manage"],"customers":["create","read","update","delete","manage"],"settings":["create","read","update","delete"],"namespace":["read","update"],"chat":["create","read","update","delete","manage"],"delivery":["create","read","update","delete","manage"],"reports":["read","manage"],"services":["create","read","update","delete","manage","deploy"],"projects":["create","read","update","delete","manage"]}'

        db.update("namespace_roles", {
            permissions = admin_permissions
        }, {
            namespace_id = namespace_id,
            role_name = "admin"
        })

        -- Update manager role
        local manager_permissions = '{"dashboard":["read"],"users":["read"],"roles":["read"],"stores":["create","read","update"],"products":["create","read","update","delete"],"orders":["create","read","update"],"customers":["create","read","update"],"settings":["read"],"namespace":["read"],"chat":["create","read","update"],"delivery":["read","update"],"reports":["read"],"services":["read","deploy"],"projects":["create","read","update"]}'

        db.update("namespace_roles", {
            permissions = manager_permissions
        }, {
            namespace_id = namespace_id,
            role_name = "manager"
        })

        -- Update member role
        local member_permissions = '{"dashboard":["read"],"stores":["read"],"products":["read"],"orders":["read"],"customers":["read"],"chat":["create","read"],"projects":["create","read","update"]}'

        db.update("namespace_roles", {
            permissions = member_permissions
        }, {
            namespace_id = namespace_id,
            role_name = "member"
        })

        -- Update viewer role
        local viewer_permissions = '{"dashboard":["read"],"stores":["read"],"products":["read"],"orders":["read"]}'

        db.update("namespace_roles", {
            permissions = viewer_permissions
        }, {
            namespace_id = namespace_id,
            role_name = "viewer"
        })
    end,

    -- ========================================
    -- [8] Initialize default menu config for existing namespaces
    -- ========================================
    [8] = function()
        local MigrationUtils = require("helper.migration-utils")
        local timestamp = MigrationUtils.getCurrentTimestamp()

        -- Get all namespaces
        local namespaces = db.select("* FROM namespaces")
        if not namespaces or #namespaces == 0 then return end

        -- Get all menu items
        local menu_items = db.select("* FROM menu_items WHERE is_active = true")
        if not menu_items or #menu_items == 0 then return end

        -- For each namespace, create default menu config (all menus enabled)
        for _, namespace in ipairs(namespaces) do
            for _, menu_item in ipairs(menu_items) do
                -- Check if config already exists
                local existing = db.select([[
                    * FROM namespace_menu_config
                    WHERE namespace_id = ? AND menu_item_id = ?
                ]], namespace.id, menu_item.id)

                if #existing == 0 then
                    db.insert("namespace_menu_config", {
                        uuid = MigrationUtils.generateUUID(),
                        namespace_id = namespace.id,
                        menu_item_id = menu_item.id,
                        is_enabled = true,
                        created_at = timestamp,
                        updated_at = timestamp
                    })
                end
            end
        end
    end,

    -- ========================================
    -- [9] Add Secret Vault menu item
    -- ========================================
    [9] = function()
        local MigrationUtils = require("helper.migration-utils")
        local timestamp = MigrationUtils.getCurrentTimestamp()

        -- Check if already exists
        local existing = db.select("* FROM menu_items WHERE key = ?", "vault")
        if #existing > 0 then return end

        -- Add vault menu item
        db.insert("menu_items", {
            uuid = MigrationUtils.generateUUID(),
            key = "vault",
            name = "Secret Vault",
            icon = "Shield",
            path = "/dashboard/namespace/vault",
            module = "vault",
            required_action = "read",
            priority = 3,  -- After My Workspace
            is_active = true,
            is_admin_only = false,
            always_show = false,
            settings = "{}",
            created_at = timestamp,
            updated_at = timestamp
        })

        -- Enable vault for all existing namespaces
        local vault_menu = db.select("* FROM menu_items WHERE key = ?", "vault")
        if #vault_menu > 0 then
            local namespaces = db.select("* FROM namespaces")
            for _, namespace in ipairs(namespaces) do
                -- Check if config already exists
                local config_exists = db.select([[
                    * FROM namespace_menu_config
                    WHERE namespace_id = ? AND menu_item_id = ?
                ]], namespace.id, vault_menu[1].id)

                if #config_exists == 0 then
                    db.insert("namespace_menu_config", {
                        uuid = MigrationUtils.generateUUID(),
                        namespace_id = namespace.id,
                        menu_item_id = vault_menu[1].id,
                        is_enabled = true,
                        created_at = timestamp,
                        updated_at = timestamp
                    })
                end
            end
        end
    end,
}
