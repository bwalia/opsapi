--[[
    NamespaceMemberQueries.lua

    Manages namespace membership - users belonging to namespaces.
    Handles adding/removing members, status changes, and role assignments.
]]

local Global = require("helper.global")
local db = require("lapis.db")
local Model = require("lapis.db.model").Model

local NamespaceMembers = Model:extend("namespace_members")
local NamespaceUserRoles = Model:extend("namespace_user_roles")
local NamespaceMemberQueries = {}

--- Add a user to a namespace
-- @param data table { namespace_id, user_id, is_owner?, status?, invited_by?, role_ids? }
-- @return table The created membership
function NamespaceMemberQueries.create(data)
    local timestamp = Global.getCurrentTimestamp()

    -- Get numeric IDs
    local namespace_id = data.namespace_id
    if type(namespace_id) == "string" then
        local ns = db.select("id FROM namespaces WHERE uuid = ? OR id = ?", namespace_id, tonumber(namespace_id) or 0)
        namespace_id = ns[1] and ns[1].id
    end

    local user_id = data.user_id
    if type(user_id) == "string" then
        local u = db.select("id FROM users WHERE uuid = ? OR id = ?", user_id, tonumber(user_id) or 0)
        user_id = u[1] and u[1].id
    end

    if not namespace_id or not user_id then
        error("Invalid namespace_id or user_id")
    end

    -- Check if already a member
    local existing = db.select("id FROM namespace_members WHERE namespace_id = ? AND user_id = ?", namespace_id, user_id)
    if #existing > 0 then
        error("User is already a member of this namespace")
    end

    local member_data = {
        uuid = data.uuid or Global.generateUUID(),
        namespace_id = namespace_id,
        user_id = user_id,
        status = data.status or "active",
        is_owner = data.is_owner or false,
        joined_at = data.status == "active" and timestamp or nil,
        invited_by = data.invited_by,
        created_at = timestamp,
        updated_at = timestamp
    }

    local member = NamespaceMembers:create(member_data, { returning = "*" })

    -- Assign roles if provided
    if data.role_ids and #data.role_ids > 0 then
        for _, role_id in ipairs(data.role_ids) do
            NamespaceMemberQueries.assignRole(member.id, role_id)
        end
    elseif not data.is_owner then
        -- Assign default role if not owner
        local default_role = db.select([[
            id FROM namespace_roles
            WHERE namespace_id = ? AND is_default = true
            LIMIT 1
        ]], namespace_id)
        if #default_role > 0 then
            NamespaceMemberQueries.assignRole(member.id, default_role[1].id)
        end
    end

    return member
end

--- Get all members of a namespace with pagination
-- @param namespace_id string|number Namespace ID or UUID
-- @param params table { page?, perPage?, status?, search?, role_id? }
-- @return table { data, total }
function NamespaceMemberQueries.all(namespace_id, params)
    params = params or {}
    local page = tonumber(params.page) or 1
    local per_page = tonumber(params.perPage) or tonumber(params.per_page) or 10
    local offset = (page - 1) * per_page

    -- Get numeric namespace ID
    local ns_id = namespace_id
    if type(namespace_id) == "string" then
        local ns = db.select("id FROM namespaces WHERE uuid = ? OR id = ?", namespace_id, tonumber(namespace_id) or 0)
        ns_id = ns[1] and ns[1].id
    end

    if not ns_id then
        return { data = {}, total = 0, page = page, per_page = per_page, total_pages = 0 }
    end

    -- Build parameterized conditions
    local conditions = { "nm.namespace_id = ?" }
    local values = { ns_id }

    if params.status and params.status ~= "" and params.status ~= "all" then
        table.insert(conditions, "nm.status = ?")
        table.insert(values, params.status)
    end

    if params.search and params.search ~= "" then
        local search_term = "%" .. params.search .. "%"
        table.insert(conditions, "(u.email ILIKE ? OR u.first_name ILIKE ? OR u.last_name ILIKE ? OR CONCAT(u.first_name, ' ', u.last_name) ILIKE ?)")
        table.insert(values, search_term)
        table.insert(values, search_term)
        table.insert(values, search_term)
        table.insert(values, search_term)
    end

    if params.role_id then
        table.insert(conditions, "EXISTS (SELECT 1 FROM namespace_user_roles nur WHERE nur.namespace_member_id = nm.id AND nur.namespace_role_id = ?)")
        table.insert(values, tonumber(params.role_id))
    end

    local where_clause = "WHERE " .. table.concat(conditions, " AND ")

    -- Get total count
    local count_query = string.format([[
        SELECT COUNT(DISTINCT nm.id) as total
        FROM namespace_members nm
        JOIN users u ON nm.user_id = u.id
        %s
    ]], where_clause)

    local count_result = db.query(count_query, table.unpack(values))
    local total = count_result and count_result[1] and count_result[1].total or 0

    -- Get paginated data with roles — append LIMIT/OFFSET to values
    local data_values = {}
    for _, v in ipairs(values) do table.insert(data_values, v) end
    table.insert(data_values, per_page)
    table.insert(data_values, offset)

    local data_query = string.format([[
        SELECT
            nm.id, nm.uuid, nm.namespace_id, nm.user_id, nm.status,
            nm.is_owner, nm.joined_at, nm.invited_by, nm.created_at, nm.updated_at,
            u.uuid as user_uuid, u.email, u.first_name, u.last_name, u.username,
            u.active as user_active,
            (
                SELECT json_agg(json_build_object(
                    'id', nr.id,
                    'uuid', nr.uuid,
                    'role_name', nr.role_name,
                    'display_name', nr.display_name
                ))
                FROM namespace_user_roles nur
                JOIN namespace_roles nr ON nur.namespace_role_id = nr.id
                WHERE nur.namespace_member_id = nm.id
            ) as roles,
            iu.first_name || ' ' || iu.last_name as invited_by_name
        FROM namespace_members nm
        JOIN users u ON nm.user_id = u.id
        LEFT JOIN users iu ON nm.invited_by = iu.id
        %s
        ORDER BY nm.is_owner DESC, nm.created_at DESC
        LIMIT ? OFFSET ?
    ]], where_clause)

    local data = db.query(data_query, table.unpack(data_values))

    -- Structure the response
    for _, member in ipairs(data or {}) do
        member.user = {
            uuid = member.user_uuid,
            email = member.email,
            first_name = member.first_name,
            last_name = member.last_name,
            username = member.username,
            active = member.user_active,
            full_name = (member.first_name or "") .. " " .. (member.last_name or "")
        }
        -- Clean up flat fields
        member.user_uuid = nil
        member.email = nil
        member.first_name = nil
        member.last_name = nil
        member.username = nil
        member.user_active = nil
    end

    return {
        data = data or {},
        total = total,
        page = page,
        per_page = per_page,
        total_pages = math.ceil(total / per_page)
    }
end

--- Find member by ID or UUID
-- @param id string|number Member ID or UUID
-- @return table|nil The member or nil
function NamespaceMemberQueries.show(id)
    local member = NamespaceMembers:find({ uuid = tostring(id) })
    if not member and tonumber(id) then
        member = NamespaceMembers:find({ id = tonumber(id) })
    end
    return member
end

--- Find membership by user and namespace
-- @param user_id string|number User ID or UUID
-- @param namespace_id string|number Namespace ID or UUID
-- @return table|nil The membership or nil
function NamespaceMemberQueries.findByUserAndNamespace(user_id, namespace_id)
    local query = [[
        SELECT nm.*
        FROM namespace_members nm
        JOIN users u ON nm.user_id = u.id
        JOIN namespaces n ON nm.namespace_id = n.id
        WHERE (u.uuid = ? OR u.id = ?)
        AND (n.uuid = ? OR n.id = ?)
        LIMIT 1
    ]]

    local result = db.query(query,
        tostring(user_id), tonumber(user_id) or 0,
        tostring(namespace_id), tonumber(namespace_id) or 0
    )

    return result and result[1] or nil
end

--- Get member with full details including roles
-- @param member_id string|number Member ID or UUID
-- @return table|nil The member with details
function NamespaceMemberQueries.getWithDetails(member_id)
    local query = [[
        SELECT
            nm.id, nm.uuid, nm.namespace_id, nm.user_id, nm.status,
            nm.is_owner, nm.joined_at, nm.invited_by, nm.created_at, nm.updated_at,
            u.uuid as user_uuid, u.email, u.first_name, u.last_name, u.username,
            n.uuid as namespace_uuid, n.name as namespace_name, n.slug as namespace_slug,
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
        FROM namespace_members nm
        JOIN users u ON nm.user_id = u.id
        JOIN namespaces n ON nm.namespace_id = n.id
        WHERE nm.uuid = ? OR nm.id = ?
        LIMIT 1
    ]]

    local result = db.query(query, tostring(member_id), tonumber(member_id) or 0)
    return result and result[1] or nil
end

--- Update member
-- @param id string|number Member ID or UUID
-- @param params table Fields to update
-- @return table|nil The updated member or nil
function NamespaceMemberQueries.update(id, params)
    local member = NamespaceMemberQueries.show(id)
    if not member then
        return nil
    end

    params.updated_at = Global.getCurrentTimestamp()

    -- Don't allow updating certain fields
    params.id = nil
    params.uuid = nil
    params.namespace_id = nil
    params.user_id = nil

    -- If status changed to active, set joined_at
    if params.status == "active" and member.status ~= "active" and not member.joined_at then
        params.joined_at = params.updated_at
    end

    member:update(params)
    -- Defensive: is_owner/status changes here affect the owner no-lock-out
    -- fallback in getPermissions. Cold path, so an unconditional bust is fine.
    require("helper.permission-cache").invalidateMember(member.id)
    return member
end

--- Remove member from namespace
-- @param id string|number Member ID or UUID
-- @return boolean Success status
function NamespaceMemberQueries.destroy(id)
    local member = NamespaceMemberQueries.show(id)
    if not member then
        return nil
    end

    -- Don't allow removing the owner if they're the last owner
    if member.is_owner then
        local other_owners = db.select([[
            id FROM namespace_members
            WHERE namespace_id = ? AND is_owner = true AND id != ?
        ]], member.namespace_id, member.id)

        if #other_owners == 0 then
            error("Cannot remove the last owner of a namespace")
        end
    end

    return member:delete()
end

--- Assign a role to a member
-- @param member_id number Member ID
-- @param role_id number Role ID
-- @return table The created assignment
function NamespaceMemberQueries.assignRole(member_id, role_id)
    local timestamp = Global.getCurrentTimestamp()

    -- Check if already assigned
    local existing = db.select([[
        id FROM namespace_user_roles
        WHERE namespace_member_id = ? AND namespace_role_id = ?
    ]], member_id, role_id)

    if #existing > 0 then
        return existing[1]
    end

    local assignment = NamespaceUserRoles:create({
        uuid = Global.generateUUID(),
        namespace_member_id = member_id,
        namespace_role_id = role_id,
        created_at = timestamp,
        updated_at = timestamp
    }, { returning = "*" })

    -- Self-invalidating so any caller (e.g. academy invite) is safe. setRoles
    -- deliberately does NOT route through here (it busts once, outside its txn).
    require("helper.permission-cache").invalidateMember(member_id)
    return assignment
end

--- Remove a role from a member
-- @param member_id number Member ID
-- @param role_id number Role ID
-- @return boolean Success status
function NamespaceMemberQueries.removeRole(member_id, role_id)
    local assignment = NamespaceUserRoles:find({
        namespace_member_id = member_id,
        namespace_role_id = role_id
    })

    if not assignment then
        return false
    end

    local deleted = assignment:delete()
    require("helper.permission-cache").invalidateMember(member_id)
    return deleted
end

--- Set member roles (replace all existing roles)
-- Uses transaction to prevent partial state if assignment fails
-- @param member_id number Member ID
-- @param role_ids table List of role IDs
-- @return boolean Success status
function NamespaceMemberQueries.setRoles(member_id, role_ids)
    -- Normalise: the form parser yields a scalar for a single value and a table
    -- for repeated keys (role_ids=1&role_ids=2), and values arrive as strings.
    -- Accept both shapes and coerce to a clean numeric id list.
    if type(role_ids) ~= "table" then
        role_ids = role_ids ~= nil and { role_ids } or {}
    end
    -- De-dupe: the raw insert below would trip UNIQUE(member,role) on a repeat
    -- id (the old assignRole loop silently deduped — preserve that).
    local ids, seen = {}, {}
    for _, rid in ipairs(role_ids) do
        local n = tonumber(rid)
        if n and not seen[n] then
            seen[n] = true
            table.insert(ids, n)
        end
    end
    role_ids = ids

    local timestamp = Global.getCurrentTimestamp()

    db.query("BEGIN")
    local ok, err = pcall(function()
        -- Remove all existing roles
        db.delete("namespace_user_roles", { namespace_member_id = member_id })

        -- Add new roles. Insert directly rather than via assignRole: the delete
        -- above cleared the set (so no dedup needed) and, more importantly, this
        -- keeps Redis calls out of the DB transaction — permission-cache is
        -- busted once after COMMIT instead of per row inside it.
        for _, role_id in ipairs(role_ids) do
            NamespaceUserRoles:create({
                uuid = Global.generateUUID(),
                namespace_member_id = member_id,
                namespace_role_id = role_id,
                created_at = timestamp,
                updated_at = timestamp
            })
        end
    end)

    if not ok then
        pcall(db.query, "ROLLBACK")
        error("Failed to set roles: " .. tostring(err))
    end

    db.query("COMMIT")
    require("helper.permission-cache").invalidateMember(member_id)
    return true
end

--- Get member's roles in a namespace
-- @param member_id number Member ID
-- @return table List of roles
function NamespaceMemberQueries.getRoles(member_id)
    return db.query([[
        SELECT nr.*
        FROM namespace_roles nr
        JOIN namespace_user_roles nur ON nr.id = nur.namespace_role_id
        WHERE nur.namespace_member_id = ?
        ORDER BY nr.priority DESC
    ]], member_id)
end

--- Get member's permissions in a namespace
-- @param member_id number Member ID
-- @return table Combined permissions from all roles
function NamespaceMemberQueries.getPermissions(member_id)
    -- Cache-aside: this runs on every authenticated namespaced request. Busted
    -- explicitly on any role/permission change (see helper.permission-cache),
    -- so a cache hit is never staler than the last write across all pods.
    local PermissionCache = require("helper.permission-cache")
    local cached = PermissionCache.get(member_id)
    if cached then
        return cached
    end

    local roles = NamespaceMemberQueries.getRoles(member_id)
    local permissions = {}

    for _, role in ipairs(roles or {}) do
        if role.permissions then
            local cjson = require("cjson")
            local ok, role_perms = pcall(cjson.decode, role.permissions)
            if ok and type(role_perms) == "table" then
                for module, actions in pairs(role_perms) do
                    if not permissions[module] then
                        permissions[module] = {}
                    end
                    for _, action in ipairs(actions) do
                        permissions[module][action] = true
                    end
                end
            end
        end
    end

    -- Convert to array format, omitting modules with no granted actions.
    -- This prevents empty entries (e.g. "tax_admin": []) from leaking into
    -- the JWT and confusing downstream permission checks.
    local result = {}
    for module, actions in pairs(permissions) do
        local arr = {}
        for action, _ in pairs(actions) do
            table.insert(arr, action)
        end
        if #arr > 0 then
            result[module] = arr
        end
    end

    -- Access is role-driven: ownership no longer bypasses permission checks on
    -- its own (menus/routes/client all read this map). But an owner must never
    -- be stranded — if they hold NO effective permissions (e.g. every role was
    -- removed), fall back to full access. An owner WITH a role (even a limited
    -- one like service_manager) is governed by that role.
    if next(result) == nil then
        local member = NamespaceMembers:find({ id = tonumber(member_id) })
            or NamespaceMembers:find({ uuid = tostring(member_id) })
        local is_owner = member and (member.is_owner == true or member.is_owner == "t" or member.is_owner == 1)
        if is_owner then
            local NamespaceRoleQueries = require("queries.NamespaceRoleQueries")
            result = NamespaceRoleQueries.getOwnerPermissions()
        end
    end

    -- Cache the final map (owner-fallback included). Ownership-flag changes bust
    -- this via transferOwnership/update, so a cached owner map can't go stale.
    PermissionCache.set(member_id, result)
    return result
end

--- Check if member has a specific permission
-- @param member_id number Member ID
-- @param module string Module name
-- @param action string Action name
-- @return boolean
function NamespaceMemberQueries.hasPermission(member_id, module, action)
    local member = NamespaceMemberQueries.show(member_id)
    if not member then
        return false
    end

    -- Access is role-driven; getPermissions() already applies the owner
    -- no-lock-out fallback, so ownership is not special-cased here.
    local permissions = NamespaceMemberQueries.getPermissions(member_id)
    local module_perms = permissions[module]
    if not module_perms then
        return false
    end
    for _, perm in ipairs(module_perms) do
        if perm == action or perm == "manage" then
            return true
        end
    end
    return false
end

--- Transfer ownership
-- Uses transaction to prevent partial ownership state
-- @param namespace_id number Namespace ID
-- @param from_user_id number Current owner user ID
-- @param to_member_id number New owner member ID
-- @return boolean Success status
function NamespaceMemberQueries.transferOwnership(namespace_id, from_user_id, to_member_id)
    local timestamp = Global.getCurrentTimestamp()

    -- Find current owner
    local current_owner = db.select([[
        id FROM namespace_members
        WHERE namespace_id = ? AND user_id = ? AND is_owner = true
    ]], namespace_id, from_user_id)

    if #current_owner == 0 then
        error("Current user is not the owner")
    end

    -- Find new owner
    local new_owner = db.select([[
        id, user_id FROM namespace_members
        WHERE id = ? AND namespace_id = ?
    ]], to_member_id, namespace_id)

    if #new_owner == 0 then
        error("Target member not found in namespace")
    end

    -- Transfer ownership in a transaction
    db.query("BEGIN")
    local ok, err = pcall(function()
        db.update("namespace_members", {
            is_owner = false,
            updated_at = timestamp
        }, { id = current_owner[1].id })

        db.update("namespace_members", {
            is_owner = true,
            updated_at = timestamp
        }, { id = to_member_id })

        db.update("namespaces", {
            owner_user_id = new_owner[1].user_id,
            updated_at = timestamp
        }, { id = namespace_id })
    end)

    if not ok then
        pcall(db.query, "ROLLBACK")
        error("Failed to transfer ownership: " .. tostring(err))
    end

    db.query("COMMIT")
    -- Both members' effective access can change: the old owner loses the
    -- no-role owner fallback, the new owner gains it.
    local PermissionCache = require("helper.permission-cache")
    PermissionCache.invalidateMember(current_owner[1].id)
    PermissionCache.invalidateMember(to_member_id)
    return true
end

--- Count members in a namespace
-- @param namespace_id number Namespace ID
-- @param status string|nil Filter by status
-- @return number
function NamespaceMemberQueries.count(namespace_id, status)
    local query = "SELECT COUNT(*) as count FROM namespace_members WHERE namespace_id = ?"
    local values = { namespace_id }

    if status then
        query = query .. " AND status = ?"
        table.insert(values, status)
    end

    local result = db.query(query, table.unpack(values))
    return result[1] and result[1].count or 0
end

return NamespaceMemberQueries
