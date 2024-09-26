local PermissionModel = require "models.PermissionModel"
local Validation = require "helper.validations"
local Global = require "helper.global"
local ModuleModel = require "models.ModuleModel"
local RolePermissionQueries = require "queries.RolePermissionQueries"
local Json = require("cjson")

local PermissionQueries = {}

function PermissionQueries.create(params)
    Validation.createPermissions(params)
    if params.uuid == nil then
        params.uuid = Global.generateUUID()
    end
    return PermissionModel:create(params, {
        returning = "*"
    })
end

function PermissionQueries.createWithModuleMName(params)
    Validation.createPermissionsWithMName(params)
    local moduleData = {
        permissions = params.permissions
    }
    local role = params.role
    local module = ModuleModel:find({
        machine_name = params.module_machine_name
    })

    local permission = PermissionModel:find({
        module_id = module.id
    })

    permission:update(moduleData, {
        returning = "*"
    })

    if permission then
        RolePermissionQueries.addRolePermission(role, permission.id)
        return permission
    end
end

function PermissionQueries.all(params)
    local page, perPage, orderField, orderDir =
        params.page or 1, params.perPage or 10, params.orderBy or 'id', params.orderDir or 'desc'

    local paginated = PermissionModel:paginated("order by " .. orderField .. " " .. orderDir, {
        per_page = perPage
    })
    -- Append the module into permissions object
    local permissions, permissionModules = paginated:get_page(page), {}
    for i, permission in ipairs(permissions) do
        permission:get_module()
        permission.module_id = nil
        table.insert(permissionModules, permission)
    end
    return {
        data = permissionModules,
        total = paginated:total_items()
    }
end

function PermissionQueries.show(id)
    return PermissionModel:find({
        uuid = id
    })
end

function PermissionQueries.update(id, params)
    local permission = PermissionModel:find({
        uuid = id
    })
    params.id = permission.id
    return permission:update(params, {
        returning = "*"
    })
end

function PermissionQueries.destroy(id)
    local permission = PermissionModel:find({
        uuid = id
    })
    return permission:delete()
end

return PermissionQueries