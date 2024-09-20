local Json = require("cjson")
local Global = require "helper.global"
local UserRolesQueries = require "queries.UserRoleQueries"
local Users = require "models.UserModel"

local UserQueries = {}

function UserQueries.create(params)
    local userData = params
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
    return paginated:get_page(page)
end

function UserQueries.show(id)
    local user = Users:find({
        uuid = id
    })
    user:get_roles()
    return user
    -- local posts = user:get_roles()
    -- ngx.say(Json.encode(posts))
    -- ngx.exit(ngx.HTTP_OK)
end

function UserQueries.update(id, params)
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