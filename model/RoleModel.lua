local Model = require("lapis.db.model").Model
local Global = require "helper.global"
local Json = require("cjson")

local Roles = Model:extend("roles", {
    timestamp = true
})
local RoleModel = {}

function RoleModel.create(roleData)
    if roleData.uuid == nil then
        roleData.uuid = Global.generateUUID()
    end
    return Roles:create(roleData, {
        returning = "*"
    })
end

function RoleModel.all(params)
    local page, perPage, orderField, orderDir =
        params.page or 1, params.perPage or 10, params.orderBy or 'id', params.orderDir or 'desc'

    local paginated = Roles:paginated("order by " .. orderField .. " " .. orderDir, {
        per_page = perPage
    })
    return paginated:get_page(page)
end

function RoleModel.show(id)
    return Roles:find({
        uuid = id
    })
end

function RoleModel.update(id, params)
    local role = Roles:find({
        uuid = id
    })
    params.id = role.id
    return role:update(params, {
        returning = "*"
    })
end

function RoleModel.destroy(id)
    local role = Roles:find({
        uuid = id
    })
    return role:delete()
end
return RoleModel