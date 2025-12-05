--[[
    NamespaceQueries.lua

    CRUD operations for namespaces (tenants/organizations).
    Each namespace represents an isolated environment for a company.
]]

local Global = require("helper.global")
local db = require("lapis.db")
local Model = require("lapis.db.model").Model

local Namespaces = Model:extend("namespaces")
local NamespaceQueries = {}

--- Generate a unique slug from name
-- @param name string The namespace name
-- @return string The generated slug
local function generateSlug(name)
    local slug = name:lower()
        :gsub("%s+", "-")      -- Replace spaces with hyphens
        :gsub("[^a-z0-9%-]", "") -- Remove non-alphanumeric except hyphens
        :gsub("%-+", "-")      -- Replace multiple hyphens with single
        :gsub("^%-", "")       -- Remove leading hyphen
        :gsub("%-$", "")       -- Remove trailing hyphen

    -- Check if slug exists, append number if needed
    local base_slug = slug
    local counter = 1
    while true do
        local existing = db.select("id FROM namespaces WHERE slug = ?", slug)
        if #existing == 0 then
            break
        end
        counter = counter + 1
        slug = base_slug .. "-" .. counter
    end

    return slug
end

--- Create a new namespace
-- @param data table { name, slug?, description?, domain?, logo_url?, plan?, settings?, max_users?, max_stores?, owner_user_id? }
-- @return table The created namespace
function NamespaceQueries.create(data)
    local timestamp = Global.getCurrentTimestamp()

    -- Generate slug if not provided
    local slug = data.slug
    if not slug or slug == "" then
        slug = generateSlug(data.name)
    end

    local namespace_data = {
        uuid = data.uuid or Global.generateUUID(),
        name = data.name,
        slug = slug,
        description = data.description,
        domain = data.domain,
        logo_url = data.logo_url,
        banner_url = data.banner_url,
        status = data.status or "active",
        plan = data.plan or "free",
        settings = data.settings or "{}",
        max_users = data.max_users or 10,
        max_stores = data.max_stores or 5,
        owner_user_id = data.owner_user_id,
        created_at = timestamp,
        updated_at = timestamp
    }

    return Namespaces:create(namespace_data, { returning = "*" })
end

--- Get all namespaces with pagination
-- @param params table { page?, perPage?, orderBy?, orderDir?, status?, search? }
-- @return table { data, total }
function NamespaceQueries.all(params)
    params = params or {}
    local page = tonumber(params.page) or 1
    local per_page = tonumber(params.perPage) or tonumber(params.per_page) or 10
    local order_by = params.orderBy or params.order_by or "created_at"
    local order_dir = params.orderDir or params.order_dir or "desc"

    -- Validate order_by to prevent SQL injection
    local valid_fields = {
        id = true, name = true, slug = true, status = true,
        plan = true, created_at = true, updated_at = true
    }
    if not valid_fields[order_by] then
        order_by = "created_at"
    end
    order_dir = order_dir:lower() == "asc" and "ASC" or "DESC"

    -- Build WHERE clause
    local conditions = {}
    local values = {}

    if params.status and params.status ~= "" and params.status ~= "all" then
        table.insert(conditions, "status = ?")
        table.insert(values, params.status)
    end

    if params.search and params.search ~= "" then
        table.insert(conditions, "(name ILIKE ? OR slug ILIKE ? OR description ILIKE ?)")
        local search_term = "%" .. params.search .. "%"
        table.insert(values, search_term)
        table.insert(values, search_term)
        table.insert(values, search_term)
    end

    local where_clause = ""
    if #conditions > 0 then
        where_clause = "WHERE " .. table.concat(conditions, " AND ")
    end

    -- Get total count
    local count_query = "SELECT COUNT(*) as total FROM namespaces " .. where_clause
    local count_result = db.query(count_query, unpack(values))
    local total = count_result and count_result[1] and count_result[1].total or 0

    -- Get paginated data
    local offset = (page - 1) * per_page
    local data_query = string.format([[
        SELECT
            id, uuid, name, slug, description, domain, logo_url, banner_url,
            status, plan, settings, max_users, max_stores, owner_user_id,
            created_at, updated_at,
            (SELECT COUNT(*) FROM namespace_members WHERE namespace_id = namespaces.id AND status = 'active') as member_count,
            (SELECT COUNT(*) FROM stores WHERE namespace_id = namespaces.id) as store_count
        FROM namespaces
        %s
        ORDER BY %s %s
        LIMIT %d OFFSET %d
    ]], where_clause, order_by, order_dir, per_page, offset)

    local data = db.query(data_query, unpack(values))

    return {
        data = data or {},
        total = total,
        page = page,
        per_page = per_page,
        total_pages = math.ceil(total / per_page)
    }
end

--- Find namespace by ID or UUID
-- @param id string|number ID or UUID
-- @return table|nil The namespace or nil
function NamespaceQueries.show(id)
    local namespace = Namespaces:find({ uuid = tostring(id) })
    if not namespace and tonumber(id) then
        namespace = Namespaces:find({ id = tonumber(id) })
    end
    return namespace
end

--- Find namespace by slug
-- @param slug string The namespace slug
-- @return table|nil The namespace or nil
function NamespaceQueries.findBySlug(slug)
    return Namespaces:find({ slug = slug })
end

--- Find namespace by domain
-- @param domain string The custom domain
-- @return table|nil The namespace or nil
function NamespaceQueries.findByDomain(domain)
    return Namespaces:find({ domain = domain })
end

--- Find namespace by ID, UUID, or slug
-- @param identifier string ID, UUID, or slug
-- @return table|nil The namespace or nil
function NamespaceQueries.findByIdentifier(identifier)
    -- Try UUID first
    local namespace = Namespaces:find({ uuid = tostring(identifier) })
    if namespace then return namespace end

    -- Try slug
    namespace = Namespaces:find({ slug = tostring(identifier) })
    if namespace then return namespace end

    -- Try numeric ID
    if tonumber(identifier) then
        namespace = Namespaces:find({ id = tonumber(identifier) })
    end

    return namespace
end

--- Update namespace
-- @param id string|number ID or UUID
-- @param params table Fields to update
-- @return table|nil The updated namespace or nil
function NamespaceQueries.update(id, params)
    local namespace = NamespaceQueries.show(id)
    if not namespace then
        return nil
    end

    -- Set updated_at timestamp
    params.updated_at = Global.getCurrentTimestamp()

    -- Don't allow updating certain fields
    params.id = nil
    params.uuid = nil

    namespace:update(params)
    return namespace
end

--- Delete namespace
-- @param id string|number ID or UUID
-- @return boolean Success status
function NamespaceQueries.destroy(id)
    local namespace = NamespaceQueries.show(id)
    if not namespace then
        return nil
    end
    return namespace:delete()
end

--- Get namespaces for a user
-- @param user_id string|number User ID or UUID
-- @return table List of namespaces
function NamespaceQueries.getForUser(user_id)
    local query = [[
        SELECT
            n.id, n.uuid, n.name, n.slug, n.description, n.logo_url,
            n.status, n.plan, n.settings,
            nm.is_owner, nm.status as member_status, nm.joined_at,
            (
                SELECT json_agg(json_build_object(
                    'id', nr.id,
                    'uuid', nr.uuid,
                    'role_name', nr.role_name,
                    'display_name', nr.display_name,
                    'permissions', nr.permissions
                ))
                FROM namespace_user_roles nur
                JOIN namespace_roles nr ON nur.namespace_role_id = nr.id
                WHERE nur.namespace_member_id = nm.id
            ) as roles
        FROM namespaces n
        JOIN namespace_members nm ON n.id = nm.namespace_id
        JOIN users u ON nm.user_id = u.id
        WHERE (u.uuid = ? OR u.id = ?)
        AND nm.status = 'active'
        AND n.status = 'active'
        ORDER BY nm.is_owner DESC, n.name ASC
    ]]

    local user_id_num = tonumber(user_id)
    return db.query(query, tostring(user_id), user_id_num or 0)
end

--- Check if user is member of namespace
-- @param user_id string|number User ID or UUID
-- @param namespace_id string|number Namespace ID or UUID
-- @return boolean
function NamespaceQueries.isUserMember(user_id, namespace_id)
    local query = [[
        SELECT nm.id
        FROM namespace_members nm
        JOIN users u ON nm.user_id = u.id
        JOIN namespaces n ON nm.namespace_id = n.id
        WHERE (u.uuid = ? OR u.id = ?)
        AND (n.uuid = ? OR n.id = ?)
        AND nm.status = 'active'
        LIMIT 1
    ]]

    local user_id_num = tonumber(user_id)
    local namespace_id_num = tonumber(namespace_id)

    local result = db.query(query,
        tostring(user_id), user_id_num or 0,
        tostring(namespace_id), namespace_id_num or 0
    )

    return result and #result > 0
end

--- Check if user is owner of namespace
-- @param user_id string|number User ID or UUID
-- @param namespace_id string|number Namespace ID or UUID
-- @return boolean
function NamespaceQueries.isUserOwner(user_id, namespace_id)
    local query = [[
        SELECT nm.id
        FROM namespace_members nm
        JOIN users u ON nm.user_id = u.id
        JOIN namespaces n ON nm.namespace_id = n.id
        WHERE (u.uuid = ? OR u.id = ?)
        AND (n.uuid = ? OR n.id = ?)
        AND nm.status = 'active'
        AND nm.is_owner = true
        LIMIT 1
    ]]

    local user_id_num = tonumber(user_id)
    local namespace_id_num = tonumber(namespace_id)

    local result = db.query(query,
        tostring(user_id), user_id_num or 0,
        tostring(namespace_id), namespace_id_num or 0
    )

    return result and #result > 0
end

--- Get namespace statistics
-- @param namespace_id string|number Namespace ID or UUID
-- @return table Statistics
function NamespaceQueries.getStats(namespace_id)
    local namespace = NamespaceQueries.show(namespace_id)
    if not namespace then
        return nil
    end

    local stats = db.query([[
        SELECT
            (SELECT COUNT(*) FROM namespace_members WHERE namespace_id = ? AND status = 'active') as total_members,
            (SELECT COUNT(*) FROM stores WHERE namespace_id = ?) as total_stores,
            (SELECT COUNT(*) FROM orders WHERE namespace_id = ?) as total_orders,
            (SELECT COUNT(*) FROM customers WHERE namespace_id = ?) as total_customers,
            (SELECT COUNT(*) FROM storeproducts WHERE namespace_id = ?) as total_products,
            (SELECT COALESCE(SUM(total_amount), 0) FROM orders WHERE namespace_id = ? AND status != 'cancelled') as total_revenue
    ]], namespace.id, namespace.id, namespace.id, namespace.id, namespace.id, namespace.id)

    return stats and stats[1] or {
        total_members = 0,
        total_stores = 0,
        total_orders = 0,
        total_customers = 0,
        total_products = 0,
        total_revenue = 0
    }
end

--- Count all namespaces
-- @param params table { status? }
-- @return number
function NamespaceQueries.count(params)
    params = params or {}
    local where_clause = ""
    local values = {}

    if params.status then
        where_clause = "WHERE status = ?"
        table.insert(values, params.status)
    end

    local result = db.query("SELECT COUNT(*) as count FROM namespaces " .. where_clause, unpack(values))
    return result[1] and result[1].count or 0
end

--- Check if slug is available
-- @param slug string The slug to check
-- @param exclude_id number|nil Namespace ID to exclude (for updates)
-- @return boolean
function NamespaceQueries.isSlugAvailable(slug, exclude_id)
    local query = "SELECT id FROM namespaces WHERE slug = ?"
    local values = { slug }

    if exclude_id then
        query = query .. " AND id != ?"
        table.insert(values, exclude_id)
    end

    local result = db.query(query, unpack(values))
    return not result or #result == 0
end

--- Check if domain is available
-- @param domain string The domain to check
-- @param exclude_id number|nil Namespace ID to exclude (for updates)
-- @return boolean
function NamespaceQueries.isDomainAvailable(domain, exclude_id)
    if not domain or domain == "" then
        return true
    end

    local query = "SELECT id FROM namespaces WHERE domain = ?"
    local values = { domain }

    if exclude_id then
        query = query .. " AND id != ?"
        table.insert(values, exclude_id)
    end

    local result = db.query(query, unpack(values))
    return not result or #result == 0
end

-- ============================================
-- User Namespace Settings (User-First Architecture)
-- ============================================

--- Get user's namespace settings (default and last active namespace)
-- @param user_id number User ID
-- @return table|nil Settings or nil
function NamespaceQueries.getUserSettings(user_id)
    local query = [[
        SELECT
            uns.*,
            dn.uuid as default_namespace_uuid,
            dn.name as default_namespace_name,
            dn.slug as default_namespace_slug,
            ln.uuid as last_active_namespace_uuid,
            ln.name as last_active_namespace_name,
            ln.slug as last_active_namespace_slug
        FROM user_namespace_settings uns
        LEFT JOIN namespaces dn ON uns.default_namespace_id = dn.id
        LEFT JOIN namespaces ln ON uns.last_active_namespace_id = ln.id
        WHERE uns.user_id = ?
    ]]
    local result = db.query(query, user_id)
    return result and result[1] or nil
end

--- Set or update user's namespace settings
-- @param user_id number User ID
-- @param settings table { default_namespace_id?, last_active_namespace_id? }
-- @return table The settings
function NamespaceQueries.setUserSettings(user_id, settings)
    local timestamp = Global.getCurrentTimestamp()

    -- Check if settings exist
    local existing = db.query("SELECT id FROM user_namespace_settings WHERE user_id = ?", user_id)

    if existing and #existing > 0 then
        -- Update existing settings
        local update_data = { updated_at = timestamp }
        if settings.default_namespace_id ~= nil then
            update_data.default_namespace_id = settings.default_namespace_id
        end
        if settings.last_active_namespace_id ~= nil then
            update_data.last_active_namespace_id = settings.last_active_namespace_id
        end

        db.update("user_namespace_settings", update_data, { user_id = user_id })
    else
        -- Create new settings record
        -- Only include fields that have valid values to avoid FK violations
        local insert_data = {
            user_id = user_id,
            created_at = timestamp,
            updated_at = timestamp
        }

        -- Only set default_namespace_id if it's a valid ID (not nil, not 0)
        if settings.default_namespace_id and settings.default_namespace_id > 0 then
            insert_data.default_namespace_id = settings.default_namespace_id
        end

        -- Only set last_active_namespace_id if it's a valid ID (not nil, not 0)
        if settings.last_active_namespace_id and settings.last_active_namespace_id > 0 then
            insert_data.last_active_namespace_id = settings.last_active_namespace_id
        end

        db.insert("user_namespace_settings", insert_data)
    end

    return NamespaceQueries.getUserSettings(user_id)
end

--- Update user's last active namespace
-- @param user_id number User ID
-- @param namespace_id number Namespace ID
-- @return table|nil The settings
function NamespaceQueries.updateLastActiveNamespace(user_id, namespace_id)
    return NamespaceQueries.setUserSettings(user_id, { last_active_namespace_id = namespace_id })
end

--- Get user's default namespace (or first available if not set)
-- @param user_id number User ID
-- @return table|nil The namespace or nil
function NamespaceQueries.getUserDefaultNamespace(user_id)
    -- First try to get the configured default
    local settings = NamespaceQueries.getUserSettings(user_id)
    if settings and settings.default_namespace_id then
        local namespace = NamespaceQueries.show(settings.default_namespace_id)
        if namespace and namespace.status == "active" then
            return namespace
        end
    end

    -- If no default or default is inactive, try last active
    if settings and settings.last_active_namespace_id then
        local namespace = NamespaceQueries.show(settings.last_active_namespace_id)
        if namespace and namespace.status == "active" then
            return namespace
        end
    end

    -- Finally, get first available namespace for user
    local namespaces = NamespaceQueries.getForUser(user_id)
    if namespaces and #namespaces > 0 then
        return NamespaceQueries.show(namespaces[1].id)
    end

    return nil
end

--- Get user's permissions in a namespace
-- @param user_id number User ID
-- @param namespace_id number Namespace ID
-- @return table Merged permissions from all roles
function NamespaceQueries.getUserPermissions(user_id, namespace_id)
    local query = [[
        SELECT nr.permissions
        FROM namespace_user_roles nur
        JOIN namespace_roles nr ON nur.namespace_role_id = nr.id
        JOIN namespace_members nm ON nur.namespace_member_id = nm.id
        WHERE nm.user_id = ? AND nm.namespace_id = ? AND nm.status = 'active'
        ORDER BY nr.priority DESC
    ]]

    local roles = db.query(query, user_id, namespace_id)
    local merged = {}

    for _, role in ipairs(roles or {}) do
        local ok, perms = pcall(require("cjson").decode, role.permissions or "{}")
        if ok and type(perms) == "table" then
            for module, actions in pairs(perms) do
                if not merged[module] then
                    merged[module] = {}
                end
                for _, action in ipairs(actions) do
                    -- Add action if not already present
                    local found = false
                    for _, existing in ipairs(merged[module]) do
                        if existing == action then
                            found = true
                            break
                        end
                    end
                    if not found then
                        table.insert(merged[module], action)
                    end
                end
            end
        end
    end

    return merged
end

--- Get user's membership in a specific namespace
-- @param user_id number User ID
-- @param namespace_id number Namespace ID
-- @return table|nil Membership details or nil
function NamespaceQueries.getUserMembership(user_id, namespace_id)
    local query = [[
        SELECT
            nm.id, nm.uuid, nm.namespace_id, nm.user_id,
            nm.status, nm.is_owner, nm.joined_at, nm.invited_by,
            nm.created_at, nm.updated_at,
            n.name as namespace_name, n.slug as namespace_slug,
            (
                SELECT json_agg(json_build_object(
                    'id', nr.id,
                    'uuid', nr.uuid,
                    'role_name', nr.role_name,
                    'display_name', nr.display_name,
                    'permissions', nr.permissions,
                    'priority', nr.priority
                ))
                FROM namespace_user_roles nur
                JOIN namespace_roles nr ON nur.namespace_role_id = nr.id
                WHERE nur.namespace_member_id = nm.id
            ) as roles
        FROM namespace_members nm
        JOIN namespaces n ON nm.namespace_id = n.id
        WHERE nm.user_id = ? AND nm.namespace_id = ?
    ]]

    local result = db.query(query, user_id, namespace_id)
    return result and result[1] or nil
end

--- Create namespace and add user as owner
-- @param user_id number The user creating the namespace
-- @param data table Namespace data
-- @return table { namespace, membership }
function NamespaceQueries.createWithOwner(user_id, data)
    local timestamp = Global.getCurrentTimestamp()

    -- Create namespace
    data.owner_user_id = user_id
    local namespace = NamespaceQueries.create(data)

    if not namespace then
        return nil, "Failed to create namespace"
    end

    -- Add user as owner member
    local member_uuid = Global.generateUUID()
    db.insert("namespace_members", {
        uuid = member_uuid,
        namespace_id = namespace.id,
        user_id = user_id,
        status = "active",
        is_owner = true,
        joined_at = timestamp,
        created_at = timestamp,
        updated_at = timestamp
    })

    -- Get member record
    local member = db.select("* FROM namespace_members WHERE uuid = ?", member_uuid)
    if not member or #member == 0 then
        return nil, "Failed to create membership"
    end

    -- Create default roles for this namespace
    local default_roles = {
        {
            role_name = "owner",
            display_name = "Owner",
            description = "Full control over the namespace",
            permissions = '{"dashboard":["create","read","update","delete","manage"],"users":["create","read","update","delete","manage"],"roles":["create","read","update","delete","manage"],"stores":["create","read","update","delete","manage"],"products":["create","read","update","delete","manage"],"orders":["create","read","update","delete","manage"],"customers":["create","read","update","delete","manage"],"settings":["create","read","update","delete","manage"],"namespace":["create","read","update","delete","manage"],"chat":["create","read","update","delete","manage"],"delivery":["create","read","update","delete","manage"],"reports":["create","read","update","delete","manage"]}',
            is_system = true,
            is_default = false,
            priority = 100
        },
        {
            role_name = "admin",
            display_name = "Administrator",
            description = "Full administrative access",
            permissions = '{"dashboard":["create","read","update","delete","manage"],"users":["create","read","update","delete"],"roles":["create","read","update","delete"],"stores":["create","read","update","delete","manage"],"products":["create","read","update","delete","manage"],"orders":["create","read","update","delete","manage"],"customers":["create","read","update","delete","manage"],"settings":["create","read","update","delete"],"namespace":["read","update"],"chat":["create","read","update","delete","manage"],"delivery":["create","read","update","delete","manage"],"reports":["read","manage"]}',
            is_system = true,
            is_default = false,
            priority = 90
        },
        {
            role_name = "manager",
            display_name = "Manager",
            description = "Manage daily operations",
            permissions = '{"dashboard":["read"],"users":["read"],"roles":["read"],"stores":["create","read","update"],"products":["create","read","update","delete"],"orders":["create","read","update"],"customers":["create","read","update"],"settings":["read"],"namespace":["read"],"chat":["create","read","update"],"delivery":["read","update"],"reports":["read"]}',
            is_system = true,
            is_default = false,
            priority = 50
        },
        {
            role_name = "member",
            display_name = "Member",
            description = "Standard member access",
            permissions = '{"dashboard":["read"],"stores":["read"],"products":["read"],"orders":["read"],"customers":["read"],"chat":["read"]}',
            is_system = true,
            is_default = true,
            priority = 20
        },
        {
            role_name = "viewer",
            display_name = "Viewer",
            description = "Read-only access",
            permissions = '{"dashboard":["read"],"stores":["read"],"products":["read"],"orders":["read"]}',
            is_system = true,
            is_default = false,
            priority = 10
        }
    }

    local owner_role_id = nil
    for _, role_data in ipairs(default_roles) do
        local role_uuid = Global.generateUUID()
        db.insert("namespace_roles", {
            uuid = role_uuid,
            namespace_id = namespace.id,
            role_name = role_data.role_name,
            display_name = role_data.display_name,
            description = role_data.description,
            permissions = role_data.permissions,
            is_system = role_data.is_system,
            is_default = role_data.is_default,
            priority = role_data.priority,
            created_at = timestamp,
            updated_at = timestamp
        })

        if role_data.role_name == "owner" then
            local role = db.select("* FROM namespace_roles WHERE uuid = ?", role_uuid)
            if role and #role > 0 then
                owner_role_id = role[1].id
            end
        end
    end

    -- Assign owner role to the user
    if owner_role_id then
        db.insert("namespace_user_roles", {
            uuid = Global.generateUUID(),
            namespace_member_id = member[1].id,
            namespace_role_id = owner_role_id,
            created_at = timestamp,
            updated_at = timestamp
        })
    end

    -- Set as user's default namespace if they don't have one
    local settings = NamespaceQueries.getUserSettings(user_id)
    if not settings or not settings.default_namespace_id then
        NamespaceQueries.setUserSettings(user_id, {
            default_namespace_id = namespace.id,
            last_active_namespace_id = namespace.id
        })
    end

    local membership = NamespaceQueries.getUserMembership(user_id, namespace.id)

    return {
        namespace = namespace,
        membership = membership
    }
end

return NamespaceQueries
