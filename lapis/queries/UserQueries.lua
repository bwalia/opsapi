local Json = require("cjson")
local Global = require "helper.global"
local UserRolesQueries = require "queries.UserRoleQueries"
local Users = require "models.UserModel"
local RoleModel = require "models.RoleModel"
local Validation = require "helper.validations"

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
        fields = "id, uuid, name, username, email, created_at, updated_at"
    })

    local users, userWithRoles = paginated:get_page(page), {}
    for userIndex, user in ipairs(users) do
        user:get_roles()
        for index, role in ipairs(user.roles) do
            local roleData = RoleModel:find(role.role_id)
            user.roles[index]["name"] = roleData.role_name
        end
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
    user:get_roles()
    for index, role in ipairs(user.roles) do
        local roleData = RoleModel:find(role.role_id)
        user.roles[index]["name"] = roleData.role_name
    end
    user.password = nil
    return user
end

function UserQueries.update(id, params)
    local validations = Validation.updateUser(params)
    ngx.say(Json.encode(validations))
    ngx.exit(ngx.HTTP_OK)
    local user = Users:find({
        uuid = id
    })
    params.id = user.id
    return user:update(params, {
        returning = "*"
    })
end

function UserQueries.destroy(id)
    local user = Users:find({
        uuid = id
    })
    return user:delete()
end
return UserQueries