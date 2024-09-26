local Global = require "helper.global"
local Modules = require "models.ModuleModel"
local Validation = require "helper.validations"
local PermissionQueries = require "queries.PermissionQueries"


local ModuleQueries = {}

function ModuleQueries.create(data)
    Validation.createModule(data)
    if data.uuid == nil then
        data.uuid = Global.generateUUID()
    end
    local module = Modules:create(data, {
        returning = "*"
    })
    if module then
        local pData = {
            module_id = module.id
        }
        PermissionQueries.create(pData)
        return module
    end
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
    local module = Modules:find({
        uuid = id
    })
    params.id = module.id
    return module:update(params, {
        returning = "*"
    })
end

function ModuleQueries.destroy(id)
    local module = Modules:find({
        uuid = id
    })
    return module:delete()
end

function ModuleQueries.getByMachineName(mName)
    local module = Modules:find({
        machine_name = mName
    })
    return module
end

return ModuleQueries