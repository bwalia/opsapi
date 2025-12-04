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

-- Default permissions structure
local DEFAULT_PERMISSIONS = {
    dashboard = { "read" },
    users = {},
    roles = {},
    stores = {},
    products = {},
    orders = {},
    customers = {},
    settings = {},
    namespace = {}
}

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

    -- Encode permissions if table
    local permissions = data.permissions
    if type(permissions) == "table" then
        permissions = cjson.encode(permissions)
    elseif not permissions then
        permissions = cjson.encode(DEFAULT_PERMISSIONS)
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
    end

    -- Encode permissions if table
    if type(params.permissions) == "table" then
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

    if members_with_role[1] and members_with_role[1].count > 0 then
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

--- Get available modules for permissions
-- @return table List of module names with descriptions
function NamespaceRoleQueries.getAvailableModules()
    return {
        { name = "dashboard", display_name = "Dashboard", description = "Main dashboard and analytics" },
        { name = "users", display_name = "Users", description = "User management within namespace" },
        { name = "roles", display_name = "Roles", description = "Role management within namespace" },
        { name = "stores", display_name = "Stores", description = "Store management" },
        { name = "products", display_name = "Products", description = "Product catalog management" },
        { name = "orders", display_name = "Orders", description = "Order processing" },
        { name = "customers", display_name = "Customers", description = "Customer management" },
        { name = "settings", display_name = "Settings", description = "Namespace settings" },
        { name = "namespace", display_name = "Namespace", description = "Namespace administration" },
        { name = "chat", display_name = "Chat", description = "Chat and messaging" },
        { name = "delivery", display_name = "Delivery", description = "Delivery partners management" },
        { name = "reports", display_name = "Reports", description = "Analytics and reports" }
    }
end

--- Get available actions for permissions
-- @return table List of action names with descriptions
function NamespaceRoleQueries.getAvailableActions()
    return {
        { name = "create", display_name = "Create", description = "Create new records" },
        { name = "read", display_name = "Read", description = "View records" },
        { name = "update", display_name = "Update", description = "Modify existing records" },
        { name = "delete", display_name = "Delete", description = "Remove records" },
        { name = "manage", display_name = "Manage", description = "Full control (includes all actions)" }
    }
end

return NamespaceRoleQueries
