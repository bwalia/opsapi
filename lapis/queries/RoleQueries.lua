local Global = require "helper.global"
local Json = require("cjson")
local Roles = require "models.RoleModel"


local RoleQueries = {}

function RoleQueries.create(roleData)
    if roleData.uuid == nil then
        roleData.uuid = Global.generateUUID()
    end
    return Roles:create(roleData, {
        returning = "*"
    })
end

function RoleQueries.all(params)
    local page, perPage, orderField, orderDir =
        params.page or 1, params.perPage or 10, params.orderBy or 'id', params.orderDir or 'desc'

    local paginated = Roles:paginated("order by " .. orderField .. " " .. orderDir, {
        per_page = perPage
    })
    return paginated:get_page(page)
end

function RoleQueries.show(id)
    return Roles:find({
        uuid = id
    })
end

function RoleQueries.update(id, params)
    local role = Roles:find({
        uuid = id
    })
    params.id = role.id
    return role:update(params, {
        returning = "*"
    })
end

function RoleQueries.destroy(id)
    local role = Roles:find({
        uuid = id
    })
    return role:delete()
end

function RoleQueries.roleByName(name)
    return Roles:find({
        role_name = tostring(name)
    })
end

return RoleQueries