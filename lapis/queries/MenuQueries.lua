--[[
    MenuQueries - Database queries for menu items (Multi-Tenant)

    Provides functions to:
    - Get menu items filtered by user permissions within namespace context
    - Manage global menu items (admin only)
    - Manage namespace-specific menu configurations

    Multi-Tenant Design:
    - Global menu_items table defines all available menu items
    - namespace_menu_config allows per-namespace customization
    - Menu filtering considers:
      1. Namespace's enabled menus (namespace_menu_config.is_enabled)
      2. User's permissions within that namespace (namespace_roles.permissions)
      3. Platform admin status (for is_admin_only items)
      4. Always-show items (visible regardless of permissions)
]]

local db = require("lapis.db")
local cjson = require("cjson")

-- Configure cjson
cjson.encode_empty_table_as_object(false)

local MenuQueries = {}

-- ============================================================
-- GLOBAL MENU ITEM QUERIES (Template Management)
-- ============================================================

-- Get all active menu items ordered by priority
function MenuQueries.all()
    local items = db.select([[
        * FROM menu_items
        WHERE is_active = true
        ORDER BY priority ASC
    ]])
    return items or {}
end

-- Get a single menu item by key
function MenuQueries.getByKey(key)
    local items = db.select("* FROM menu_items WHERE key = ? LIMIT 1", key)
    return items and items[1]
end

-- Get a single menu item by id
function MenuQueries.show(id)
    local items
    -- Check if id is numeric or UUID
    if tonumber(id) then
        items = db.select("* FROM menu_items WHERE id = ? LIMIT 1", tonumber(id))
    else
        items = db.select("* FROM menu_items WHERE uuid = ? OR key = ? LIMIT 1", id, id)
    end
    return items and items[1]
end

-- Create a new menu item (global template)
function MenuQueries.create(data)
    local MigrationUtils = require("helper.migration-utils")
    local timestamp = MigrationUtils.getCurrentTimestamp()

    local result = db.insert("menu_items", {
        uuid = MigrationUtils.generateUUID(),
        key = data.key,
        name = data.name,
        icon = data.icon,
        path = data.path,
        module = data.module,
        required_action = data.required_action or "read",
        parent_id = data.parent_id,
        priority = data.priority or 50,
        is_active = data.is_active ~= false,
        is_admin_only = data.is_admin_only or false,
        always_show = data.always_show or false,
        badge_key = data.badge_key,
        settings = data.settings and cjson.encode(data.settings) or "{}",
        created_at = timestamp,
        updated_at = timestamp
    })

    -- Initialize menu config for all existing namespaces
    if result and result.id then
        local namespaces = db.select("id FROM namespaces")
        for _, ns in ipairs(namespaces or {}) do
            pcall(function()
                db.insert("namespace_menu_config", {
                    uuid = MigrationUtils.generateUUID(),
                    namespace_id = ns.id,
                    menu_item_id = result.id,
                    is_enabled = true,
                    created_at = timestamp,
                    updated_at = timestamp
                })
            end)
        end
    end

    return MenuQueries.show(result.id)
end

-- Update a menu item
function MenuQueries.update(id, data)
    local item = MenuQueries.show(id)
    if not item then
        return nil, "Menu item not found"
    end

    local MigrationUtils = require("helper.migration-utils")
    local timestamp = MigrationUtils.getCurrentTimestamp()

    local update_data = {
        updated_at = timestamp
    }

    if data.name ~= nil then update_data.name = data.name end
    if data.icon ~= nil then update_data.icon = data.icon end
    if data.path ~= nil then update_data.path = data.path end
    if data.module ~= nil then update_data.module = data.module end
    if data.required_action ~= nil then update_data.required_action = data.required_action end
    if data.parent_id ~= nil then update_data.parent_id = data.parent_id end
    if data.priority ~= nil then update_data.priority = data.priority end
    if data.is_active ~= nil then update_data.is_active = data.is_active end
    if data.is_admin_only ~= nil then update_data.is_admin_only = data.is_admin_only end
    if data.always_show ~= nil then update_data.always_show = data.always_show end
    if data.badge_key ~= nil then update_data.badge_key = data.badge_key end
    if data.settings ~= nil then
        update_data.settings = type(data.settings) == "table" and cjson.encode(data.settings) or data.settings
    end

    db.update("menu_items", update_data, { id = item.id })
    return MenuQueries.show(item.id)
end

-- Delete a menu item
function MenuQueries.destroy(id)
    local item = MenuQueries.show(id)
    if not item then
        return nil, "Menu item not found"
    end

    -- Cascade delete will remove namespace_menu_config entries
    db.delete("menu_items", { id = item.id })
    return true
end

-- ============================================================
-- NAMESPACE-SPECIFIC MENU QUERIES
-- ============================================================

-- Get menu items for a specific namespace with namespace customizations applied
-- @param namespace_id - the namespace ID
-- @param namespace_permissions - table of permissions from user's role e.g., {dashboard={"read"}, users={"read","update"}}
-- @param is_namespace_owner - boolean, if true grants all permissions within namespace
-- @param is_platform_admin - boolean, if true shows platform admin-only items
-- @param project_code - string|nil, namespace's project_code to filter items by enabled features
function MenuQueries.getForNamespace(namespace_id, namespace_permissions, is_namespace_owner, is_platform_admin, project_code)
    -- Query menu items with namespace-specific config
    local items = db.query([[
        SELECT
            mi.*,
            COALESCE(nmc.is_enabled, true) as ns_enabled,
            nmc.custom_name,
            nmc.custom_icon,
            nmc.custom_priority
        FROM menu_items mi
        LEFT JOIN namespace_menu_config nmc ON mi.id = nmc.menu_item_id AND nmc.namespace_id = ?
        WHERE mi.is_active = true
        ORDER BY COALESCE(nmc.custom_priority, mi.priority) ASC
    ]], namespace_id)

    if not items then
        return {}
    end

    -- Build a set of allowed modules for this namespace's project_code
    -- This ensures items for disabled features (e.g., orders, products for tax_copilot) are hidden
    --
    -- Two layers of filtering:
    -- 1. Namespace's DB project_code controls what this namespace INTENDS to use
    -- 2. Environment PROJECT_CODE controls what routes are ACTUALLY loaded
    -- Menu items must pass BOTH checks — an item whose route isn't loaded must not appear
    local allowed_modules = nil
    local ProjectConfig = require("helper.project-config")

    -- Determine the effective project_code for filtering
    -- If the namespace has "all" or no project_code, fall back to the environment PROJECT_CODE
    -- This prevents showing menu items for routes that aren't loaded
    local effective_code = project_code
    if not effective_code or effective_code == "" or effective_code == "all" then
        effective_code = ProjectConfig.getProjectCode()
    end

    if effective_code and effective_code ~= "" and effective_code ~= "all" then
        allowed_modules = {}

        -- Collect modules from all enabled features for this project code
        local proj_features = ProjectConfig.PROJECT_FEATURES[effective_code]
        if proj_features then
            for _, feature in ipairs(proj_features) do
                local feature_modules = ProjectConfig.PROJECT_MODULES[feature]
                if feature_modules then
                    for _, m in ipairs(feature_modules) do
                        allowed_modules[m.machine_name] = true
                    end
                end
            end
        end

        -- Also check direct module mapping (e.g., PROJECT_MODULES["tax_copilot"])
        local proj_modules = ProjectConfig.PROJECT_MODULES[effective_code]
        if proj_modules then
            for _, m in ipairs(proj_modules) do
                allowed_modules[m.machine_name] = true
            end
        end

        -- Always include core modules
        local core_modules = ProjectConfig.PROJECT_MODULES.core
        if core_modules then
            for _, m in ipairs(core_modules) do
                allowed_modules[m.machine_name] = true
            end
        end
    end

    local filtered_items = {}

    for _, item in ipairs(items) do
        local should_include = false

        -- Skip if disabled for this namespace
        if not item.ns_enabled then
            goto continue
        end

        -- Skip items whose module is not relevant to this project
        -- (e.g., hide "orders" menu for tax_copilot even for owners)
        -- Admin-only items bypass this check — they're platform-level, not project-scoped
        if allowed_modules and item.module and not item.is_admin_only and not allowed_modules[item.module] then
            goto continue
        end

        -- Always show items marked as always_show (e.g., My Workspace)
        if item.always_show then
            should_include = true
        -- Platform admin-only items only shown to platform admins
        elseif item.is_admin_only then
            if is_platform_admin then
                should_include = true
            end
        -- Namespace owners see items for modules in their project
        elseif is_namespace_owner then
            should_include = true
        -- Check permission based on module
        elseif item.module then
            -- Check if user has the required permission in this namespace
            if namespace_permissions then
                local module_perms = namespace_permissions[item.module]
                if module_perms then
                    -- Check if user has the required action or "manage" (which grants all)
                    local required_action = item.required_action or "read"
                    for _, action in ipairs(module_perms) do
                        if action == required_action or action == "manage" then
                            should_include = true
                            break
                        end
                    end
                end
            end
        else
            -- Items without module requirement are shown to all namespace members
            should_include = true
        end

        if should_include then
            table.insert(filtered_items, {
                key = item.key,
                name = item.custom_name or item.name,
                icon = item.custom_icon or item.icon,
                path = item.path,
                module = item.module,
                priority = item.custom_priority or item.priority,
                badge_key = item.badge_key,
                always_show = item.always_show,
                is_admin_only = item.is_admin_only
            })
        end

        ::continue::
    end

    return filtered_items
end

-- Legacy function for backward compatibility
function MenuQueries.getForUser(namespace_permissions, is_namespace_owner, is_platform_admin)
    -- When no namespace context, return all items that user might have access to
    -- This is a fallback - in normal operation, always use getForNamespace
    local all_items = db.select([[
        * FROM menu_items
        WHERE is_active = true
        ORDER BY priority ASC
    ]])

    if not all_items then
        return {}
    end

    local filtered_items = {}

    for _, item in ipairs(all_items) do
        local should_include = false

        if item.always_show then
            should_include = true
        elseif item.is_admin_only then
            if is_platform_admin then
                should_include = true
            end
        elseif is_namespace_owner then
            should_include = true
        elseif item.module then
            if namespace_permissions then
                local module_perms = namespace_permissions[item.module]
                if module_perms then
                    local required_action = item.required_action or "read"
                    for _, action in ipairs(module_perms) do
                        if action == required_action or action == "manage" then
                            should_include = true
                            break
                        end
                    end
                end
            end
        else
            should_include = true
        end

        if should_include then
            table.insert(filtered_items, {
                key = item.key,
                name = item.name,
                icon = item.icon,
                path = item.path,
                module = item.module,
                priority = item.priority,
                badge_key = item.badge_key,
                always_show = item.always_show,
                is_admin_only = item.is_admin_only
            })
        end
    end

    return filtered_items
end

-- ============================================================
-- NAMESPACE MENU CONFIG MANAGEMENT
-- ============================================================

-- Get menu config for a specific namespace
function MenuQueries.getNamespaceConfig(namespace_id)
    local configs = db.query([[
        SELECT
            nmc.*,
            mi.key as menu_key,
            mi.name as default_name,
            mi.icon as default_icon,
            mi.path,
            mi.module,
            mi.priority as default_priority,
            mi.is_admin_only,
            mi.always_show
        FROM namespace_menu_config nmc
        JOIN menu_items mi ON nmc.menu_item_id = mi.id
        WHERE nmc.namespace_id = ? AND mi.is_active = true
        ORDER BY COALESCE(nmc.custom_priority, mi.priority) ASC
    ]], namespace_id)
    return configs or {}
end

-- Update menu config for a specific menu item in a namespace
function MenuQueries.updateNamespaceMenuConfig(namespace_id, menu_key, data)
    local MigrationUtils = require("helper.migration-utils")
    local timestamp = MigrationUtils.getCurrentTimestamp()

    -- Find menu item
    local menu_item = MenuQueries.getByKey(menu_key)
    if not menu_item then
        return nil, "Menu item not found"
    end

    -- Check if config exists
    local existing = db.select([[
        * FROM namespace_menu_config
        WHERE namespace_id = ? AND menu_item_id = ?
    ]], namespace_id, menu_item.id)

    if #existing > 0 then
        -- Update existing config
        local update_data = { updated_at = timestamp }
        if data.is_enabled ~= nil then update_data.is_enabled = data.is_enabled end
        if data.custom_name ~= nil then update_data.custom_name = data.custom_name end
        if data.custom_icon ~= nil then update_data.custom_icon = data.custom_icon end
        if data.custom_priority ~= nil then update_data.custom_priority = data.custom_priority end
        if data.settings ~= nil then
            update_data.settings = type(data.settings) == "table" and cjson.encode(data.settings) or data.settings
        end

        db.update("namespace_menu_config", update_data, { id = existing[1].id })
        return db.select("* FROM namespace_menu_config WHERE id = ?", existing[1].id)[1]
    else
        -- Create new config
        local result = db.insert("namespace_menu_config", {
            uuid = MigrationUtils.generateUUID(),
            namespace_id = namespace_id,
            menu_item_id = menu_item.id,
            is_enabled = data.is_enabled ~= false,
            custom_name = data.custom_name,
            custom_icon = data.custom_icon,
            custom_priority = data.custom_priority,
            settings = data.settings and cjson.encode(data.settings) or "{}",
            created_at = timestamp,
            updated_at = timestamp
        })
        return db.select("* FROM namespace_menu_config WHERE id = ?", result.id)[1]
    end
end

-- Batch update menu configs for a namespace
function MenuQueries.batchUpdateNamespaceConfig(namespace_id, configs)
    local results = {}
    for menu_key, config in pairs(configs) do
        local result, err = MenuQueries.updateNamespaceMenuConfig(namespace_id, menu_key, config)
        if result then
            results[menu_key] = { success = true, config = result }
        else
            results[menu_key] = { success = false, error = err }
        end
    end
    return results
end

-- Enable a menu item for a namespace
function MenuQueries.enableMenuItem(namespace_id, menu_key)
    return MenuQueries.updateNamespaceMenuConfig(namespace_id, menu_key, { is_enabled = true })
end

-- Disable a menu item for a namespace
function MenuQueries.disableMenuItem(namespace_id, menu_key)
    return MenuQueries.updateNamespaceMenuConfig(namespace_id, menu_key, { is_enabled = false })
end

-- Initialize default menu configs for a new namespace
function MenuQueries.initNamespaceMenus(namespace_id)
    local MigrationUtils = require("helper.migration-utils")
    local timestamp = MigrationUtils.getCurrentTimestamp()

    local menu_items = db.select("* FROM menu_items WHERE is_active = true")
    if not menu_items then return end

    for _, item in ipairs(menu_items) do
        -- Check if already exists
        local existing = db.select([[
            * FROM namespace_menu_config
            WHERE namespace_id = ? AND menu_item_id = ?
        ]], namespace_id, item.id)

        if #existing == 0 then
            pcall(function()
                db.insert("namespace_menu_config", {
                    uuid = MigrationUtils.generateUUID(),
                    namespace_id = namespace_id,
                    menu_item_id = item.id,
                    is_enabled = true,
                    created_at = timestamp,
                    updated_at = timestamp
                })
            end)
        end
    end
end

-- Get child menu items
function MenuQueries.getChildren(parent_id)
    local items = db.select([[
        * FROM menu_items
        WHERE parent_id = ? AND is_active = true
        ORDER BY priority ASC
    ]], parent_id)
    return items or {}
end

-- Get menu tree (items with their children)
function MenuQueries.getTree()
    local all_items = MenuQueries.all()
    local items_by_id = {}
    local root_items = {}

    -- First pass: index by id
    for _, item in ipairs(all_items) do
        item.children = {}
        items_by_id[item.id] = item
    end

    -- Second pass: build tree
    for _, item in ipairs(all_items) do
        if item.parent_id and items_by_id[item.parent_id] then
            table.insert(items_by_id[item.parent_id].children, item)
        else
            table.insert(root_items, item)
        end
    end

    return root_items
end

return MenuQueries
