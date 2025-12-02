local PermissionModel = require "models.PermissionModel"
local Validation = require "helper.validations"
local Global = require "helper.global"
local ModuleModel = require "models.ModuleModel"
local RoleQueries = require "queries.RoleQueries"

local PermissionQueries = {}

function PermissionQueries.create(params)
    Validation.createPermissions(params)
    local module = ModuleModel:find({
        machine_name = params.module_machine_name
    })
    local role = RoleQueries.roleByName(params.role)
    local pData = {
        module_id = module.id,
        permissions = params.permissions,
        role_id = role.id,
        uuid = Global.generateUUID()
    }
    return PermissionModel:create(pData, {
        returning = "*"
    })
end

function PermissionQueries.createWithModuleId(params)
    Validation.createPermissionsWithMName(params)
    local role = RoleQueries.roleByName(params.role)
    local moduleData = {
        permissions = params.permissions,
        role_id = role.id,
        module_id = params.module_id,
        uuid = Global.generateUUID()
    }
    return PermissionModel:create(moduleData, {
        returning = "*"
    })
end

function PermissionQueries.all(params)
    local page, perPage, orderField, orderDir =
        params.page or 1, params.perPage or 10, params.orderBy or 'id', params.orderDir or 'desc'

    -- Build WHERE clause for filtering
    local whereClause = ""
    local roleFilter = params.role

    if roleFilter then
        -- Get role ID by name
        local role = RoleQueries.roleByName(roleFilter)
        if role then
            whereClause = "where role_id = " .. role.id .. " "
        else
            -- Role not found, return empty
            return {
                data = {},
                total = 0
            }
        end
    end

    local paginated = PermissionModel:paginated(whereClause .. "order by " .. orderField .. " " .. orderDir, {
        per_page = perPage
    })

    -- Append the module info into permissions object
    local permissions = paginated:get_page(page)
    local permissionsList = {}

    for _, permission in ipairs(permissions) do
        permission:get_module()
        permission:get_role()
        -- Add module_machine_name from the module relation
        if permission.module then
            permission.module_machine_name = permission.module.machine_name
        end
        permission.module_id = nil
        permission.role_id = nil
        table.insert(permissionsList, permission)
    end

    return {
        data = permissionsList,
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