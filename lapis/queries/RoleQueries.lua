local Global = require "helper.global"
local Roles = require "models.RoleModel"
local Validation = require "helper.validations"


local RoleQueries = {}

function RoleQueries.create(roleData)
    Validation.createRole(roleData)
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
        per_page = perPage,
        fields = 'id as internal_id, uuid as id, role_name, created_at, updated_at'
    })
    return {
        data = paginated:get_page(page),
        total = paginated:total_items()
    }
end

function RoleQueries.show(id)
    local role = Roles:find({
        uuid = id
    })
    if role then
        role.internal_id = role.id
        role.id = role.uuid
    end
    return role
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