local Json = require("cjson")
local Global = require "helper.global"
local UserRolesQueries = require "queries.UserRoleQueries"
local Users = require "models.UserModel"
local RoleModel = require "models.RoleModel"
local Validation = require "helper.validations"
local bcrypt = require("bcrypt")

local UserQueries = {}

function UserQueries.create(params)
    local db = require("lapis.db")
    local userData = params
    -- Validate the user data
    Validation.createUser(userData)
    local role = params.role
    local namespace_id = params.namespace_id  -- Optional: specific namespace to add user to
    local namespace_role = params.namespace_role  -- Optional: role within namespace
    userData.role = nil
    userData.namespace_id = nil
    userData.namespace_role = nil
    if userData.uuid == nil then
        userData.uuid = Global.generateUUID()
    end

    userData.password = Global.hashPassword(userData.password)
    local user = Users:create(userData, {
        returning = "*"
    })
    user.password = nil

    -- Add global role (legacy system)
    UserRolesQueries.addRole(user.id, role)

    -- Auto-add user to a namespace
    local target_namespace_id = namespace_id
    if not target_namespace_id then
        -- Default to "System" namespace
        local system_ns = db.select("id FROM namespaces WHERE slug = ?", "system")
        if system_ns and #system_ns > 0 then
            target_namespace_id = system_ns[1].id
        end
    end

    if target_namespace_id then
        -- Check if not already a member
        local existing = db.select("id FROM namespace_members WHERE namespace_id = ? AND user_id = ?", target_namespace_id, user.id)
        if not existing or #existing == 0 then
            -- Add user as member
            local member_uuid = Global.generateUUID()
            local timestamp = os.date("!%Y-%m-%d %H:%M:%S")

            db.insert("namespace_members", {
                uuid = member_uuid,
                namespace_id = target_namespace_id,
                user_id = user.id,
                status = "active",
                is_owner = false,
                joined_at = timestamp,
                created_at = timestamp,
                updated_at = timestamp
            })

            -- Get the member record
            local member = db.select("id FROM namespace_members WHERE uuid = ?", member_uuid)
            if member and #member > 0 then
                -- Assign role (default to "member" if not specified)
                local role_name = namespace_role or "member"
                local ns_role = db.select("id FROM namespace_roles WHERE namespace_id = ? AND role_name = ?", target_namespace_id, role_name)

                if ns_role and #ns_role > 0 then
                    db.insert("namespace_user_roles", {
                        uuid = Global.generateUUID(),
                        namespace_member_id = member[1].id,
                        namespace_role_id = ns_role[1].id,
                        created_at = timestamp,
                        updated_at = timestamp
                    })
                end

                -- Create user namespace settings
                local settings_exist = db.select("id FROM user_namespace_settings WHERE user_id = ?", user.id)
                if not settings_exist or #settings_exist == 0 then
                    db.insert("user_namespace_settings", {
                        user_id = user.id,
                        default_namespace_id = target_namespace_id,
                        last_active_namespace_id = target_namespace_id,
                        created_at = timestamp,
                        updated_at = timestamp
                    })
                end
            end
        end
    end

    return user
end

function UserQueries.all(params)
    local page, perPage, orderField, orderDir =
        params.page or 1, params.perPage or 10, params.orderBy or 'id', params.orderDir or 'desc'

    local paginated = Users:paginated("order by " .. orderField .. " " .. orderDir, {
        per_page = perPage,
        fields = "id, uuid, first_name, last_name, username, email, active, created_at, updated_at"
    })

    -- Append the role into user object
    local users, userWithRoles = paginated:get_page(page), {}
    for userIndex, user in ipairs(users) do
        user:get_roles()
        for index, role in ipairs(user.roles) do
            local roleData = RoleModel:find(role.role_id)
            user.roles[index]["name"] = roleData.role_name
        end
        user.internal_id = user.id
        user.id = user.uuid
        table.insert(userWithRoles, user)
    end
    return {
        data = userWithRoles,
        total = paginated:total_items()
    }
end

function UserQueries.show(id)
    local user = Users:find({
        uuid = id
    })
    if user then
        user:get_roles()
        for index, role in ipairs(user.roles) do
            local roleData = RoleModel:find(role.role_id)
            user.roles[index]["name"] = roleData.role_name
            user.roles[index]["role_name"] = roleData.role_name
        end
        user.password = nil
        user.internal_id = user.id
        user.id = user.uuid
        return user, ngx.HTTP_OK
    end
end

-- Get detailed user info including namespace memberships
function UserQueries.showDetailed(id)
    local db = require("lapis.db")
    local user = Users:find({
        uuid = id
    })
    if not user then
        return nil
    end

    -- Get roles
    user:get_roles()
    for index, role in ipairs(user.roles) do
        local roleData = RoleModel:find(role.role_id)
        user.roles[index]["name"] = roleData.role_name
        user.roles[index]["role_name"] = roleData.role_name
    end
    user.password = nil

    -- Get namespace memberships
    local memberships = db.query([[
        SELECT
            nm.id as membership_id,
            nm.status as membership_status,
            nm.is_owner,
            nm.created_at as joined_at,
            n.id as namespace_id,
            n.uuid as namespace_uuid,
            n.name as namespace_name,
            n.slug as namespace_slug,
            n.logo_url as namespace_logo,
            n.status as namespace_status
        FROM namespace_members nm
        JOIN namespaces n ON nm.namespace_id = n.id
        WHERE nm.user_id = ?
        ORDER BY nm.created_at DESC
    ]], user.id)

    -- Get namespace roles for each membership
    for _, membership in ipairs(memberships or {}) do
        local roles = db.query([[
            SELECT nr.id, nr.role_name, nr.display_name
            FROM namespace_user_roles nur
            JOIN namespace_roles nr ON nur.namespace_role_id = nr.id
            WHERE nur.namespace_member_id = ?
        ]], membership.membership_id)
        membership.roles = roles or {}
    end

    user.namespaces = memberships or {}
    user.internal_id = user.id
    user.id = user.uuid

    return user, ngx.HTTP_OK
end

function UserQueries.update(id, params)
    local user = Users:find({
        uuid = id
    })
    params.id = nil
    return user:update(params, {
        returning = "*"
    })
end

function UserQueries.destroy(id)
    local user = Users:find({
        uuid = id
    })
    if user then
        UserRolesQueries.deleteByUid(user.id)
        return user:delete()
    end
end

function UserQueries.verify(identifier, plain_password)
    -- Try to find user by email first
    local user = Users:find({ email = identifier })

    -- If not found by email, try username
    if not user then
        user = Users:find({ username = identifier })
    end

    -- Verify password
    if user and bcrypt.verify(plain_password, user.password) then
        return user
    end
    return nil
end

function UserQueries.findByEmail(email)
    return Users:find({ email = email })
end

function UserQueries.findByOAuth(provider, oauth_id)
    return Users:find({ oauth_provider = provider, oauth_id = oauth_id })
end

function UserQueries.createOAuthUser(params)
    local userData = {
        uuid = params.uuid or Global.generateUUID(),
        email = params.email,
        username = params.username or params.email,
        first_name = params.first_name or "",
        last_name = params.last_name or "",
        password = params.password,
        oauth_provider = params.oauth_provider,
        oauth_id = params.oauth_id,
        active = params.active or true
    }
    
    local user = Users:create(userData, {
        returning = "*"
    })
    user.password = nil
    
    -- Add default role
    UserRolesQueries.addRole(user.id, params.role or "buyer")
    return user
end

-- SCIM user response
function UserQueries.SCIMall(params)
    local page, perPage, orderField, orderDir =
        params.page or 1, params.perPage or 10, params.orderBy or 'id', params.orderDir or 'desc'

    local paginated = Users:paginated("order by " .. orderField .. " " .. orderDir, {
        per_page = perPage,
        fields = "id, uuid, first_name, last_name, username, email, active, created_at, updated_at"
    })

    -- Append the role into user object
    local users, userWithRoles = paginated:get_page(page), {}
    for userIndex, user in ipairs(users) do
        user:get_roles()
        for index, role in ipairs(user.roles) do
            local roleData = RoleModel:find(role.role_id)
            user.roles[index] = { value = roleData.role_name }
        end
        table.insert(userWithRoles, Global.scimUserSchema(user))
    end
    return {
        Resources = userWithRoles,
        totalResults = paginated:total_items()
    }
end

function UserQueries.SCIMcreate(params)
    local userData = params
    -- Validate the user data
    Validation.createUser(userData)
    local role = params.role
    userData.role = nil
    if userData.uuid == nil then
        userData.uuid = Global.generateUUID()
    end

    userData.password = Global.hashPassword(userData.password)
    local user = Users:create(userData, {
        returning = "*"
    })
    user.password = nil

    UserRolesQueries.addRole(user.id, role)
    return user
end

function UserQueries.SCIMupdate(id, params)
    -- local user = Users:find({
    --     uuid = id
    -- })
    -- params.id = nil

    -- local firstName, lastName = params.displayName:match("^(%S+)%s+(%S+)$")
    -- local userParams = {
    --     first_name = firstName,
    --     lastName = lastName,
    --     phone_no = params.phoneNumbers,
    -- }
    return {}, 204
    -- return user:update(userParams, {
    --     returning = "*"
    -- }), 204
end

-- Search users by email, name, or username
function UserQueries.search(params)
    local db = require("lapis.db")
    local query = params.query or params.q or ""
    local limit = tonumber(params.limit) or 10
    local exclude_namespace_id = params.exclude_namespace_id

    if query == "" then
        return { data = {}, total = 0 }
    end

    -- Escape the query for LIKE pattern
    local search_pattern = "%" .. query:lower() .. "%"

    local sql
    if exclude_namespace_id then
        -- Exclude users already in the namespace
        sql = [[
            SELECT u.id, u.uuid, u.email, u.first_name, u.last_name, u.username
            FROM users u
            WHERE (
                LOWER(u.email) LIKE ? OR
                LOWER(u.first_name) LIKE ? OR
                LOWER(u.last_name) LIKE ? OR
                LOWER(u.username) LIKE ? OR
                LOWER(CONCAT(u.first_name, ' ', u.last_name)) LIKE ?
            )
            AND u.id NOT IN (
                SELECT nm.user_id FROM namespace_members nm
                WHERE nm.namespace_id = ? AND nm.status = 'active'
            )
            ORDER BY u.email ASC
            LIMIT ?
        ]]
        local users = db.query(sql, search_pattern, search_pattern, search_pattern, search_pattern, search_pattern, exclude_namespace_id, limit)
        return {
            data = users or {},
            total = #(users or {})
        }
    else
        sql = [[
            SELECT u.id, u.uuid, u.email, u.first_name, u.last_name, u.username
            FROM users u
            WHERE (
                LOWER(u.email) LIKE ? OR
                LOWER(u.first_name) LIKE ? OR
                LOWER(u.last_name) LIKE ? OR
                LOWER(u.username) LIKE ? OR
                LOWER(CONCAT(u.first_name, ' ', u.last_name)) LIKE ?
            )
            ORDER BY u.email ASC
            LIMIT ?
        ]]
        local users = db.query(sql, search_pattern, search_pattern, search_pattern, search_pattern, search_pattern, limit)
        return {
            data = users or {},
            total = #(users or {})
        }
    end
end

return UserQueries
