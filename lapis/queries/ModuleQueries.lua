local Global = require "helper.global"
local Modules = require "models.ModuleModel"
local Validation = require "helper.validations"


local ModuleQueries = {}

function ModuleQueries.create(data)
    Validation.createModule(data)
    if data.uuid == nil then
        data.uuid = Global.generateUUID()
    end
    return Modules:create(data, {
        returning = "*"
    })
end

function ModuleQueries.all(params)
    local page, perPage, orderField, orderDir =
        params.page or 1, params.perPage or 10, params.orderBy or 'id', params.orderDir or 'desc'

    local paginated = Modules:paginated("order by " .. orderField .. " " .. orderDir, {
        per_page = perPage
    })
    return paginated:get_page(page)
end

function ModuleQueries.show(id)
    return Modules:find({
        uuid = id
    })
end

function ModuleQueries.update(id, params)
    local role = Modules:find({
        uuid = id
    })
    params.id = role.id
    return role:update(params, {
        returning = "*"
    })
end

function ModuleQueries.destroy(id)
    local role = Modules:find({
        uuid = id
    })
    return role:delete()
end

return ModuleQueries