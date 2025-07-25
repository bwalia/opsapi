local Json = require("cjson")
local Global = require "helper.global"
local UserRolesQueries = require "queries.UserRoleQueries"
local Users = require "models.UserModel"
local RoleModel = require "models.RoleModel"
local Validation = require "helper.validations"
local bcrypt = require("bcrypt")

local UserQueries = {}

function UserQueries.create(params)
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
        end
        user.password = nil
        user.internal_id = user.id
        user.id = user.uuid
        return user, ngx.HTTP_OK
    end
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

function UserQueries.verify(email, plain_password)
    local user = Users:find({ email = email })
    if user and bcrypt.verify(plain_password, user.password) then
        return user
    end
    return nil
end

function UserQueries.findByEmail(email)
    return Users:find({ email = email })
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

return UserQueries
