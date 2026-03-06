--[[
    NamespaceRoleQueries.lua

    Manages namespace-specific roles and permissions.
    Each namespace can have its own set of roles with custom permissions.
]]

local Global = require("helper.global")
local db = require("lapis.db")
local Model = require("lapis.db.model").Model
local cjson = require("cjson")

local NamespaceRoles = Model:extend("namespace_roles")
local NamespaceRoleQueries = {}

-- Valid permission actions — reject anything not in this set
local VALID_ACTIONS = {
    access = true, create = true, read = true, update = true, delete = true, manage = true, reply = true
}

--- Validate permissions object: check actions are valid and modules exist in DB
-- @param permissions table The permissions object { module_name = { actions } }
-- @return boolean, string|nil true if valid, or false with error message
local function validatePermissions(permissions)
    if type(permissions) ~= "table" then
        return true -- will be handled elsewhere
    end

    -- Load valid module names from DB
    local valid_modules = {}
    local db_modules = db.query("SELECT machine_name FROM modules WHERE is_active = true")
    for _, m in ipairs(db_modules or {}) do
        valid_modules[m.machine_name] = true
    end

    for module_name, actions in pairs(permissions) do
        -- Validate module exists
        if not valid_modules[module_name] then
            return false, "Unknown module: " .. tostring(module_name)
        end

        -- Validate actions
        if type(actions) ~= "table" then
            return false, "Actions for module '" .. module_name .. "' must be an array"
        end

        for _, action in ipairs(actions) do
            if not VALID_ACTIONS[action] then
                return false, "Invalid action '" .. tostring(action) .. "' for module '" .. module_name
                    .. "'. Valid actions: create, read, update, delete, manage"
            end
        end
    end

    return true
end

--- Create a new namespace role
-- @param data table { namespace_id, role_name, display_name?, description?, permissions?, is_default?, priority? }
-- @return table The created role
function NamespaceRoleQueries.create(data)
    local timestamp = Global.getCurrentTimestamp()

    -- Get numeric namespace ID
    local namespace_id = data.namespace_id
    if type(namespace_id) == "string" then
        local ns = db.select("id FROM namespaces WHERE uuid = ? OR id = ?", namespace_id, tonumber(namespace_id) or 0)
        namespace_id = ns[1] and ns[1].id
    end

    if not namespace_id then
        error("Invalid namespace_id")
    end

    -- Check if role name already exists in namespace
    local existing = db.select([[
        id FROM namespace_roles WHERE namespace_id = ? AND role_name = ?
    ]], namespace_id, data.role_name)

    if #existing > 0 then
        error("Role name already exists in this namespace")
    end

    -- Validate and encode permissions
    local permissions = data.permissions
    if type(permissions) == "table" then
        local valid, err = validatePermissions(permissions)
        if not valid then
            error(err)
        end
        permissions = cjson.encode(permissions)
    elseif not permissions then
        permissions = cjson.encode(NamespaceRoleQueries.getEmptyPermissions())
    end

    local role_data = {
        uuid = data.uuid or Global.generateUUID(),
        namespace_id = namespace_id,
        role_name = data.role_name,
        display_name = data.display_name or data.role_name,
        description = data.description,
        permissions = permissions,
        is_system = data.is_system or false,
        is_default = data.is_default or false,
        priority = data.priority or 0,
        created_at = timestamp,
        updated_at = timestamp
    }

    -- If this role is set as default, unset other defaults
    if role_data.is_default then
        db.update("namespace_roles", { is_default = false }, { namespace_id = namespace_id })
    end

    return NamespaceRoles:create(role_data, { returning = "*" })
end

--- Get all roles for a namespace
-- @param namespace_id string|number Namespace ID or UUID
-- @param params table { include_system?, include_member_count? }
-- @return table List of roles
function NamespaceRoleQueries.all(namespace_id, params)
    params = params or {}

    -- Get numeric namespace ID
    local ns_id = namespace_id
    if type(namespace_id) == "string" then
        local ns = db.select("id FROM namespaces WHERE uuid = ? OR id = ?", namespace_id, tonumber(namespace_id) or 0)
        ns_id = ns[1] and ns[1].id
    end

    if not ns_id then
        return {}
    end

    local query
    if params.include_member_count then
        query = [[
            SELECT
                nr.*,
                (SELECT COUNT(*) FROM namespace_user_roles nur WHERE nur.namespace_role_id = nr.id) as member_count
            FROM namespace_roles nr
            WHERE nr.namespace_id = ?
            ORDER BY nr.priority DESC, nr.role_name ASC
        ]]
    else
        query = [[
            SELECT * FROM namespace_roles
            WHERE namespace_id = ?
            ORDER BY priority DESC, role_name ASC
        ]]
    end

    local roles = db.query(query, ns_id)

    -- Parse permissions JSON
    for _, role in ipairs(roles or {}) do
        if role.permissions and type(role.permissions) == "string" then
            local ok, parsed = pcall(cjson.decode, role.permissions)
            if ok then
                role.permissions_parsed = parsed
            end
        end
    end

    return roles or {}
end

--- Find role by ID or UUID
-- @param id string|number Role ID or UUID
-- @return table|nil The role or nil
function NamespaceRoleQueries.show(id)
    local role = NamespaceRoles:find({ uuid = tostring(id) })
    if not role and tonumber(id) then
        role = NamespaceRoles:find({ id = tonumber(id) })
    end

    if role and role.permissions and type(role.permissions) == "string" then
        local ok, parsed = pcall(cjson.decode, role.permissions)
        if ok then
            role.permissions_parsed = parsed
        end
    end

    return role
end

--- Find role by name in a namespace
-- @param namespace_id number Namespace ID
-- @param role_name string Role name
-- @return table|nil The role or nil
function NamespaceRoleQueries.findByName(namespace_id, role_name)
    local role = NamespaceRoles:find({
        namespace_id = namespace_id,
        role_name = role_name
    })

    if role and role.permissions and type(role.permissions) == "string" then
        local ok, parsed = pcall(cjson.decode, role.permissions)
        if ok then
            role.permissions_parsed = parsed
        end
    end

    return role
end

--- Get the default role for a namespace
-- @param namespace_id number Namespace ID
-- @return table|nil The default role or nil
function NamespaceRoleQueries.getDefault(namespace_id)
    local roles = db.select([[
        * FROM namespace_roles
        WHERE namespace_id = ? AND is_default = true
        LIMIT 1
    ]], namespace_id)

    return roles[1] or nil
end

--- Update a role
-- @param id string|number Role ID or UUID
-- @param params table Fields to update
-- @return table|nil The updated role or nil
function NamespaceRoleQueries.update(id, params)
    local role = NamespaceRoleQueries.show(id)
    if not role then
        return nil
    end

    -- Don't allow updating system roles' core fields
    if role.is_system then
        params.role_name = nil
        params.is_system = nil
        -- Owner role always has full access — permissions cannot be stripped
        if role.role_name == "owner" then
            params.permissions = nil
        end
    end

    -- Validate and encode permissions if table
    if type(params.permissions) == "table" then
        local valid, err = validatePermissions(params.permissions)
        if not valid then
            error(err)
        end
        params.permissions = cjson.encode(params.permissions)
    end

    params.updated_at = Global.getCurrentTimestamp()

    -- Don't allow updating certain fields
    params.id = nil
    params.uuid = nil
    params.namespace_id = nil

    -- If this role is set as default, unset other defaults
    if params.is_default then
        db.update("namespace_roles", { is_default = false }, { namespace_id = role.namespace_id })
    end

    role:update(params)

    -- Re-parse permissions for return
    if role.permissions and type(role.permissions) == "string" then
        local ok, parsed = pcall(cjson.decode, role.permissions)
        if ok then
            role.permissions_parsed = parsed
        end
    end

    return role
end

--- Delete a role
-- @param id string|number Role ID or UUID
-- @return boolean Success status
function NamespaceRoleQueries.destroy(id)
    local role = NamespaceRoleQueries.show(id)
    if not role then
        return nil
    end

    -- Don't allow deleting system roles
    if role.is_system then
        error("Cannot delete system roles")
    end

    -- Check if any members have this role
    local members_with_role = db.select([[
        COUNT(*) as count FROM namespace_user_roles
        WHERE namespace_role_id = ?
    ]], role.id)

    if members_with_role[1] and tonumber(members_with_role[1].count) > 0 then
        error("Cannot delete role that is assigned to members. Remove role from all members first.")
    end

    return role:delete()
end

--- Clone default roles to a new namespace
-- @param source_namespace_id number Source namespace ID (usually the system namespace)
-- @param target_namespace_id number Target namespace ID
-- @return table List of created roles
function NamespaceRoleQueries.cloneDefaultRoles(source_namespace_id, target_namespace_id)
    local source_roles = NamespaceRoleQueries.all(source_namespace_id)
    local created_roles = {}

    for _, role in ipairs(source_roles) do
        local new_role = NamespaceRoleQueries.create({
            namespace_id = target_namespace_id,
            role_name = role.role_name,
            display_name = role.display_name,
            description = role.description,
            permissions = role.permissions,
            is_system = role.is_system,
            is_default = role.is_default,
            priority = role.priority
        })
        table.insert(created_roles, new_role)
    end

    return created_roles
end

--- Set permission for a role
-- @param role_id number Role ID
-- @param module string Module name
-- @param actions table List of actions (create, read, update, delete, manage)
-- @return table Updated role
function NamespaceRoleQueries.setModulePermissions(role_id, module, actions)
    local role = NamespaceRoleQueries.show(role_id)
    if not role then
        return nil
    end

    -- Validate actions
    for _, action in ipairs(actions or {}) do
        if not VALID_ACTIONS[action] then
            error("Invalid action '" .. tostring(action) .. "'. Valid: create, read, update, delete, manage")
        end
    end

    local permissions = role.permissions_parsed or {}
    permissions[module] = actions

    return NamespaceRoleQueries.update(role_id, {
        permissions = permissions
    })
end

--- Add a single permission to a role
-- @param role_id number Role ID
-- @param module string Module name
-- @param action string Action name
-- @return table Updated role
function NamespaceRoleQueries.addPermission(role_id, module, action)
    -- Validate action
    if not VALID_ACTIONS[action] then
        error("Invalid action '" .. tostring(action) .. "'. Valid: create, read, update, delete, manage")
    end

    local role = NamespaceRoleQueries.show(role_id)
    if not role then
        return nil
    end

    local permissions = role.permissions_parsed or {}
    if not permissions[module] then
        permissions[module] = {}
    end

    -- Check if action already exists
    for _, existing_action in ipairs(permissions[module]) do
        if existing_action == action then
            return role
        end
    end

    table.insert(permissions[module], action)

    return NamespaceRoleQueries.update(role_id, {
        permissions = permissions
    })
end

--- Remove a single permission from a role
-- @param role_id number Role ID
-- @param module string Module name
-- @param action string Action name
-- @return table Updated role
function NamespaceRoleQueries.removePermission(role_id, module, action)
    local role = NamespaceRoleQueries.show(role_id)
    if not role then
        return nil
    end

    local permissions = role.permissions_parsed or {}
    if not permissions[module] then
        return role
    end

    local new_actions = {}
    for _, existing_action in ipairs(permissions[module]) do
        if existing_action ~= action then
            table.insert(new_actions, existing_action)
        end
    end
    permissions[module] = new_actions

    return NamespaceRoleQueries.update(role_id, {
        permissions = permissions
    })
end

--- Check if a role has a specific permission
-- @param role_id number Role ID
-- @param module string Module name
-- @param action string Action name
-- @return boolean
function NamespaceRoleQueries.hasPermission(role_id, module, action)
    local role = NamespaceRoleQueries.show(role_id)
    if not role then
        return false
    end

    local permissions = role.permissions_parsed or {}
    if not permissions[module] then
        return false
    end

    for _, existing_action in ipairs(permissions[module]) do
        if existing_action == action or existing_action == "manage" then
            return true
        end
    end

    return false
end

--- Get members with a specific role
-- @param role_id number Role ID
-- @param params table { page?, perPage? }
-- @return table { data, total }
function NamespaceRoleQueries.getMembers(role_id, params)
    params = params or {}
    local page = tonumber(params.page) or 1
    local per_page = tonumber(params.perPage) or 10
    local offset = (page - 1) * per_page

    -- Get total count
    local count_result = db.query([[
        SELECT COUNT(*) as total
        FROM namespace_user_roles nur
        JOIN namespace_members nm ON nur.namespace_member_id = nm.id
        WHERE nur.namespace_role_id = ?
    ]], role_id)
    local total = count_result and count_result[1] and count_result[1].total or 0

    -- Get members
    local members = db.query([[
        SELECT
            nm.id, nm.uuid, nm.status, nm.is_owner, nm.joined_at,
            u.uuid as user_uuid, u.email, u.first_name, u.last_name, u.username
        FROM namespace_user_roles nur
        JOIN namespace_members nm ON nur.namespace_member_id = nm.id
        JOIN users u ON nm.user_id = u.id
        WHERE nur.namespace_role_id = ?
        ORDER BY nm.created_at DESC
        LIMIT ? OFFSET ?
    ]], role_id, per_page, offset)

    return {
        data = members or {},
        total = total,
        page = page,
        per_page = per_page,
        total_pages = math.ceil(total / per_page)
    }
end

--- Count roles in a namespace
-- @param namespace_id number Namespace ID
-- @return number
function NamespaceRoleQueries.count(namespace_id)
    local result = db.query("SELECT COUNT(*) as count FROM namespace_roles WHERE namespace_id = ?", namespace_id)
    return result[1] and result[1].count or 0
end

--- Get available modules for permissions (reads from DB)
-- When project_code is provided (and not "all"), filters to only modules
-- defined in ProjectConfig.PROJECT_MODULES for that project.
-- @param project_code string|nil Optional project code to filter modules
-- @return table List of module names with descriptions
function NamespaceRoleQueries.getAvailableModules(project_code)
    local results = db.query(
        "SELECT machine_name as name, name as display_name, description, category, allowed_actions "
        .. "FROM modules WHERE is_active = true ORDER BY name"
    )
    results = results or {}

    -- Parse allowed_actions JSON from DB (stored as JSON array or NULL)
    for _, mod in ipairs(results) do
        if mod.allowed_actions and mod.allowed_actions ~= "" then
            local ok, parsed = pcall(cjson.decode, mod.allowed_actions)
            if ok and type(parsed) == "table" then
                mod.allowed_actions = parsed
            else
                mod.allowed_actions = nil  -- NULL means full CRUD
            end
        else
            mod.allowed_actions = nil
        end
    end

    -- If no project_code or "all", return everything
    if not project_code or project_code == "" or project_code == "all" then
        return results
    end

    -- Build a set of allowed machine_names from ProjectConfig
    local ProjectConfig = require("helper.project-config")
    local allowed = {}

    -- Always include core modules
    local core_modules = ProjectConfig.PROJECT_MODULES.core
    if core_modules then
        for _, m in ipairs(core_modules) do
            allowed[m.machine_name] = true
        end
    end

    -- Add project-specific modules
    local project_modules = ProjectConfig.PROJECT_MODULES[project_code]
    if project_modules then
        for _, m in ipairs(project_modules) do
            allowed[m.machine_name] = true
        end
    end

    -- Also check PROJECT_FEATURES for multi-feature projects
    local project_features = ProjectConfig.PROJECT_FEATURES[project_code]
    if project_features then
        for _, feature in ipairs(project_features) do
            local feature_modules = ProjectConfig.PROJECT_MODULES[feature]
            if feature_modules then
                for _, m in ipairs(feature_modules) do
                    allowed[m.machine_name] = true
                end
            end
        end
    end

    -- Filter results to only allowed modules
    local filtered = {}
    for _, mod in ipairs(results) do
        if allowed[mod.name] then
            table.insert(filtered, mod)
        end
    end

    return filtered
end

--- Get modules enabled for a specific namespace (filtered by namespace settings).
-- If the namespace has no `enabled_modules` setting, all project modules are returned.
-- @param namespace_id number Namespace ID
-- @param project_code string|nil Optional project code
-- @return table List of enabled modules
function NamespaceRoleQueries.getEnabledModules(namespace_id, project_code)
    local all_modules = NamespaceRoleQueries.getAvailableModules(project_code)

    if not namespace_id then
        return all_modules
    end

    -- Load namespace settings
    local ns = db.query("SELECT settings FROM namespaces WHERE id = ?", namespace_id)
    if not ns or #ns == 0 or not ns[1].settings then
        return all_modules
    end

    local ok, settings = pcall(cjson.decode, ns[1].settings)
    if not ok or type(settings) ~= "table" then
        return all_modules
    end

    local enabled = settings.enabled_modules
    if not enabled or type(enabled) ~= "table" or #enabled == 0 then
        return all_modules  -- no filter set = show all
    end

    -- Build lookup set
    local enabled_set = {}
    for _, name in ipairs(enabled) do
        enabled_set[name] = true
    end

    -- Filter
    local filtered = {}
    for _, mod in ipairs(all_modules) do
        if enabled_set[mod.name] then
            table.insert(filtered, mod)
        end
    end
    return filtered
end

--- Get all available modules with their enabled status for a namespace.
-- Used by the Settings page to show toggles.
-- @param namespace_id number Namespace ID
-- @param project_code string|nil Optional project code
-- @return table List of modules with `enabled` boolean field
function NamespaceRoleQueries.getModulesWithStatus(namespace_id, project_code)
    local all_modules = NamespaceRoleQueries.getAvailableModules(project_code)

    -- Default: everything enabled
    local enabled_set = nil

    if namespace_id then
        local ns = db.query("SELECT settings FROM namespaces WHERE id = ?", namespace_id)
        if ns and #ns > 0 and ns[1].settings then
            local ok, settings = pcall(cjson.decode, ns[1].settings)
            if ok and type(settings) == "table" and settings.enabled_modules and type(settings.enabled_modules) == "table" and #settings.enabled_modules > 0 then
                enabled_set = {}
                for _, name in ipairs(settings.enabled_modules) do
                    enabled_set[name] = true
                end
            end
        end
    end

    -- Add enabled flag to each module
    for _, mod in ipairs(all_modules) do
        if enabled_set then
            mod.enabled = enabled_set[mod.name] or false
        else
            mod.enabled = true  -- all enabled by default
        end
    end

    return all_modules
end

--- Get available actions for permissions
-- @return table List of action names with descriptions
function NamespaceRoleQueries.getAvailableActions()
    return {
        { name = "access", display_name = "Access", description = "Grant access to this module" },
        { name = "create", display_name = "Create", description = "Create new records" },
        { name = "read", display_name = "Read", description = "View records" },
        { name = "update", display_name = "Update", description = "Modify existing records" },
        { name = "delete", display_name = "Delete", description = "Remove records" },
        { name = "reply", display_name = "Reply", description = "Reply to conversations or messages" },
        { name = "manage", display_name = "Manage", description = "Full control (includes all actions)" }
    }
end

--- Get full permissions for owner (all modules with manage permission)
-- @param project_code string|nil Optional project code to filter modules
-- @return table Full permissions object
function NamespaceRoleQueries.getOwnerPermissions(project_code)
    local modules = NamespaceRoleQueries.getAvailableModules(project_code)
    local permissions = {}
    for _, module in ipairs(modules) do
        permissions[module.name] = { "manage" }
    end
    return permissions
end

--- Get default admin permissions (all except namespace management)
-- @param project_code string|nil Optional project code to filter modules
-- @return table Admin permissions object
function NamespaceRoleQueries.getAdminPermissions(project_code)
    local modules = NamespaceRoleQueries.getAvailableModules(project_code)
    local permissions = {}
    for _, module in ipairs(modules) do
        if module.name == "namespace" then
            permissions[module.name] = { "read" }
        else
            permissions[module.name] = { "manage" }
        end
    end
    return permissions
end

--- Get empty permissions for all active modules (no access by default)
-- Used for non-admin roles — permissions must be explicitly granted
-- @param project_code string|nil Optional project code to filter modules
-- @return table Empty permissions object
function NamespaceRoleQueries.getEmptyPermissions(project_code)
    local modules = NamespaceRoleQueries.getAvailableModules(project_code)
    local permissions = {}
    for _, module in ipairs(modules) do
        permissions[module.name] = {}
    end
    return permissions
end

--- Create default roles for a new namespace
-- Creates 3 DB-driven roles: owner (full), admin (full except namespace), member (empty)
-- When project_code is provided, permissions are scoped to that project's modules only
-- @param namespace_id number Namespace ID
-- @param project_code string|nil Optional project code to filter modules
-- @return table List of created roles
function NamespaceRoleQueries.createDefaultRoles(namespace_id, project_code)
    local created_roles = {}

    -- Owner role (all modules with manage permission)
    local owner_role = NamespaceRoleQueries.create({
        namespace_id = namespace_id,
        role_name = "owner",
        display_name = "Owner",
        description = "Full namespace control",
        permissions = NamespaceRoleQueries.getOwnerPermissions(project_code),
        is_system = true,
        is_default = false,
        priority = 100
    })
    table.insert(created_roles, owner_role)

    -- Admin role (manage on all except namespace = read)
    local admin_role = NamespaceRoleQueries.create({
        namespace_id = namespace_id,
        role_name = "admin",
        display_name = "Administrator",
        description = "Full access to all namespace features",
        permissions = NamespaceRoleQueries.getAdminPermissions(project_code),
        is_system = true,
        is_default = false,
        priority = 90
    })
    table.insert(created_roles, admin_role)

    -- Member role (empty permissions — must be explicitly granted)
    local member_role = NamespaceRoleQueries.create({
        namespace_id = namespace_id,
        role_name = "member",
        display_name = "Member",
        description = "Permissions must be explicitly granted",
        permissions = NamespaceRoleQueries.getEmptyPermissions(project_code),
        is_system = true,
        is_default = true,
        priority = 10
    })
    table.insert(created_roles, member_role)

    return created_roles
end

return NamespaceRoleQueries
