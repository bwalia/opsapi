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
    - Platform super-admins (role "administrative") see every active menu
      for the deployment — including plugins turned off in the workspace and
      items toggled off in namespace_menu_config — so they can operate any
      workspace without hunting for a toggle first.
]]

local db = require("lapis.db")
-- A private cjson: this module wants empty tables as [], and changing the
-- shared instance would turn every other module's empty objects ({}) into [].
local cjson = require("cjson").new()
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

    -- Enable this new item for every existing namespace in ONE set-based insert
    -- (was one round-trip per namespace — O(tenants)). ON CONFLICT covers the
    -- UNIQUE(namespace_id, menu_item_id) so re-runs are idempotent.
    if result and result.id then
        db.query([[
            INSERT INTO namespace_menu_config
                (uuid, namespace_id, menu_item_id, is_enabled, created_at, updated_at)
            SELECT gen_random_uuid()::text, n.id, ?, true, ?, ?
            FROM namespaces n
            ON CONFLICT (namespace_id, menu_item_id) DO NOTHING
        ]], result.id, timestamp, timestamp)
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
-- SIDEBAR GROUPS
-- ============================================================
-- The sidebar shows items in collapsible groups, in this order. Each plugin
-- gets its own group ("plugin:<code>", named after the plugin) just before
-- Administration. Items in no group (Dashboard, AI Navigator) sit at the top.
-- A new module's menu key goes in GROUP_OF (or matches a PREFIX_GROUPS rule);
-- one item can also pick a group with menu_items.settings = {"group": "<key>"}.
MenuQueries.GROUPS = {
    { key = "sales", name = "Sales & CRM", icon = "Contact" },
    { key = "finance", name = "Finance", icon = "Wallet" },
    { key = "commerce", name = "Shop & Orders", icon = "ShoppingCart" },
    { key = "work", name = "Projects & Team", icon = "Kanban" },
    { key = "field_service", name = "Field Service", icon = "Wrench" },
    { key = "healthcare", name = "Healthcare", icon = "Heart" },
    { key = "tax", name = "Tax", icon = "Calculator" },
    { key = "content", name = "Content & Learning", icon = "BookOpen" },
    { key = "admin", name = "Administration", icon = "Building2" },
    { key = "developer", name = "Developer", icon = "Code" },
}

MenuQueries.GROUP_OF = {
    crm = "sales", crm_leads = "sales", customers = "sales", forms = "sales",
    invoices = "finance", purchase_orders = "finance", accounting = "finance", document_templates = "finance",
    billing = "finance",
    shop = "commerce", orders = "commerce", products = "commerce", stores = "commerce", delivery = "commerce",
    projects = "work", timesheets = "work", employees = "work",
    hospitals = "healthcare", patients = "healthcare", care_home = "healthcare",
    tax = "tax",
    cms = "content", academy = "content",
    namespace = "admin", users = "admin", roles = "admin", activity = "admin", reports = "admin",
    plugins = "admin", namespaces = "admin", sso = "admin",
    ["api-keys"] = "developer", webhooks = "developer", vault = "developer", domains = "developer",
    services = "developer",
}

local PREFIX_GROUPS = {
    { "field_service_", "field_service" }, { "tax_", "tax" }, { "billing_", "finance" }, { "crm_", "sales" },
}

local KNOWN_GROUP = {}
for _, g in ipairs(MenuQueries.GROUPS) do KNOWN_GROUP[g.key] = true end

--- The sidebar group of a menu_items row (nil = top level, ungrouped).
function MenuQueries.groupOf(item)
    local key = item.key or ""
    local settings = item.settings
    if type(settings) == "string" then
        local ok, decoded = pcall(cjson.decode, settings)
        settings = ok and decoded or nil
    end
    local chosen = type(settings) == "table" and settings.group
    if type(chosen) == "string" and (KNOWN_GROUP[chosen] or chosen:match("^plugin:[%w_]+$")) then
        return chosen
    end
    if MenuQueries.GROUP_OF[key] then return MenuQueries.GROUP_OF[key] end
    for _, rule in ipairs(PREFIX_GROUPS) do
        if key:sub(1, #rule[1]) == rule[1] then return rule[2] end
    end
    local plugin = key:match("^plugin:([^:]+):")
    return plugin and ("plugin:" .. plugin) or nil
end

--- The groups these (already filtered) items use, in sidebar order: { key, name, icon }.
function MenuQueries.groupsFor(items)
    local used = {}
    for _, item in ipairs(items) do
        if item.group then used[item.group] = true end
    end
    local out = {}
    local function add(g)
        if used[g.key] then out[#out + 1] = g end
    end
    for _, g in ipairs(MenuQueries.GROUPS) do
        if g.key == "admin" then
            for _, m in ipairs(require("helper.project-loader").getRegistered()) do
                add({ key = "plugin:" .. m.code, name = m.name or m.code, icon = m.icon or "Puzzle" })
            end
        end
        add(g)
    end
    return out
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
    local ProjectLoader = require("helper.project-loader")

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

        -- Plugins are installed for the whole deployment: their modules count
        -- for every project code.
        for _, plugin in ipairs(ProjectLoader.getRegistered()) do
            for _, m in ipairs(plugin.modules) do
                allowed_modules[m.machine_name] = true
            end
        end

        -- Feature-only codes (e.g. "services") are deployment-wide add-ons
        -- layered onto EVERY namespace of this deployment (see project-config
        -- FEATURE_ONLY_CODES) — the namespace's own project_code never lists
        -- them. Merge their feature modules in from the environment PROJECT_CODE
        -- so their menu items (e.g. Domains) appear wherever their routes are
        -- actually loaded; without this a `tax_copilot,services` deployment
        -- migrates + serves /api/v2/domains but the sidebar item stays hidden.
        local env_code = ProjectConfig.getProjectCode() or ""
        for code in env_code:gmatch("[^,]+") do
            code = code:gsub("^%s+", ""):gsub("%s+$", "")
            if ProjectConfig.isFeatureOnlyCode and ProjectConfig.isFeatureOnlyCode(code) then
                local feats = ProjectConfig.PROJECT_FEATURES[code]
                if feats then
                    for _, feature in ipairs(feats) do
                        local fmods = ProjectConfig.PROJECT_MODULES[feature]
                        if fmods then
                            for _, m in ipairs(fmods) do
                                allowed_modules[m.machine_name] = true
                            end
                        end
                    end
                end
            end
        end
    end

    local filtered_items = {}
    -- A plugin may list one page under several entries (each needs a single module, e.g. AI Runs' Work log for
    -- ai_runs or ai_terminal_worklogs): show it once, as the first entry that applies.
    local plugin_paths = {}

    -- Plugins turned off in this workspace (one query for the whole menu).
    local plugin_codes = {}
    for _, m in ipairs(ProjectLoader.getRegistered()) do plugin_codes[#plugin_codes + 1] = m.code end
    local plugins_off = require("helper.plugin-workspaces").disabledIn(namespace_id, plugin_codes)

    for _, item in ipairs(items) do
        local should_include = false
        local plugin_code = item.key and item.key:match("^plugin:([^:]+):")

        -- Plugin removed from the deployment: hide for everyone (incl. super-admin).
        if plugin_code and not ProjectLoader.getByCode(plugin_code) then
            goto continue
        end
        if item.key == "plugins" and #plugin_codes == 0 then
            goto continue
        end

        -- Platform super-admin: every active menu in this deployment, including
        -- workspace-disabled plugins and namespace_menu_config toggles. Project
        -- module filter still applies so tax_copilot etc. don't show shop items
        -- whose routes aren't loaded — unless the module is a registered plugin.
        if is_platform_admin then
            if allowed_modules and item.module and not item.is_admin_only
                and not allowed_modules[item.module] and not plugin_code then
                goto continue
            end
            should_include = true
        else
            -- Skip if disabled for this namespace
            if not item.ns_enabled then
                goto continue
            end

            -- Plugin pages only while the plugin is on in this workspace.
            if plugin_code and plugins_off[plugin_code] then
                goto continue
            end

            -- Skip items whose module is not relevant to this project
            -- (e.g., hide "orders" menu for tax_copilot even for owners)
            if allowed_modules and item.module and not item.is_admin_only
                and not allowed_modules[item.module] then
                goto continue
            end

            -- Always show items marked as always_show (e.g., My Workspace)
            if item.always_show then
                should_include = true
            -- Platform admin-only items (already handled above for is_platform_admin)
            elseif item.is_admin_only then
                should_include = false
            -- Role-driven: an owner's menu follows their role's permissions like any
            -- member (the owner role grants everything by default; a limited role
            -- limits the menu). Ownership no longer forces every item in.
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
                -- Items without module requirement are shown to all namespace members
                should_include = true
            end
        end

        if should_include and plugin_code and item.path then
            if plugin_paths[item.path] then
                should_include = false
            else
                plugin_paths[item.path] = true
            end
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
                is_admin_only = item.is_admin_only,
                group = MenuQueries.groupOf(item)
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
        }, "id")
        -- db.insert only returns the row when asked; without "id" result.id was nil
        -- and the read-back crashed (500) after the row had already been saved.
        return db.select("* FROM namespace_menu_config WHERE id = ?", result[1].id)[1]
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

    -- Enable all active items for this namespace in one insert. ON CONFLICT
    -- makes it idempotent, replacing the old per-item exists-check + insert loop.
    db.query([[
        INSERT INTO namespace_menu_config
            (uuid, namespace_id, menu_item_id, is_enabled, created_at, updated_at)
        SELECT gen_random_uuid()::text, ?, mi.id, true, ?, ?
        FROM menu_items mi
        WHERE mi.is_active = true
        ON CONFLICT (namespace_id, menu_item_id) DO NOTHING
    ]], namespace_id, timestamp, timestamp)
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
