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

    -- Build conditions
    local conditions = { "nm.namespace_id = " .. ns_id }

    if params.status and params.status ~= "" and params.status ~= "all" then
        table.insert(conditions, "nm.status = " .. db.escape_literal(params.status))
    end

    if params.search and params.search ~= "" then
        local search_term = db.escape_literal("%" .. params.search .. "%")
        table.insert(conditions, string.format(
            "(u.email ILIKE %s OR u.first_name ILIKE %s OR u.last_name ILIKE %s OR CONCAT(u.first_name, ' ', u.last_name) ILIKE %s)",
            search_term, search_term, search_term, search_term
        ))
    end

    if params.role_id then
        table.insert(conditions, string.format(
            "EXISTS (SELECT 1 FROM namespace_user_roles nur WHERE nur.namespace_member_id = nm.id AND nur.namespace_role_id = %d)",
            tonumber(params.role_id)
        ))
    end

    local where_clause = "WHERE " .. table.concat(conditions, " AND ")

    -- Get total count
    local count_query = string.format([[
        SELECT COUNT(DISTINCT nm.id) as total
        FROM namespace_members nm
        JOIN users u ON nm.user_id = u.id
        %s
    ]], where_clause)

    local count_result = db.query(count_query)
    local total = count_result and count_result[1] and count_result[1].total or 0

    -- Get paginated data with roles
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
        LIMIT %d OFFSET %d
    ]], where_clause, per_page, offset)

    local data = db.query(data_query)

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

    return NamespaceUserRoles:create({
        uuid = Global.generateUUID(),
        namespace_member_id = member_id,
        namespace_role_id = role_id,
        created_at = timestamp,
        updated_at = timestamp
    }, { returning = "*" })
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

    return assignment:delete()
end

--- Set member roles (replace all existing roles)
-- @param member_id number Member ID
-- @param role_ids table List of role IDs
-- @return boolean Success status
function NamespaceMemberQueries.setRoles(member_id, role_ids)
    -- Remove all existing roles
    db.delete("namespace_user_roles", { namespace_member_id = member_id })

    -- Add new roles
    for _, role_id in ipairs(role_ids or {}) do
        NamespaceMemberQueries.assignRole(member_id, role_id)
    end

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

    -- Convert to array format
    local result = {}
    for module, actions in pairs(permissions) do
        result[module] = {}
        for action, _ in pairs(actions) do
            table.insert(result[module], action)
        end
    end

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

    -- Owners have all permissions
    if member.is_owner then
        return true
    end

    local permissions = NamespaceMemberQueries.getPermissions(member_id)
    return permissions[module] and permissions[module][action]
end

--- Transfer ownership
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
        id FROM namespace_members
        WHERE id = ? AND namespace_id = ?
    ]], to_member_id, namespace_id)

    if #new_owner == 0 then
        error("Target member not found in namespace")
    end

    -- Transfer ownership
    db.update("namespace_members", {
        is_owner = false,
        updated_at = timestamp
    }, { id = current_owner[1].id })

    db.update("namespace_members", {
        is_owner = true,
        updated_at = timestamp
    }, { id = to_member_id })

    -- Update namespace owner_user_id
    local new_owner_details = NamespaceMemberQueries.show(to_member_id)
    if new_owner_details then
        db.update("namespaces", {
            owner_user_id = new_owner_details.user_id,
            updated_at = timestamp
        }, { id = namespace_id })
    end

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
