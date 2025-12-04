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
    if not module then
        error("Module not found: " .. tostring(params.module_machine_name))
    end
    local role = RoleQueries.roleByName(params.role)
    if not role then
        error("Role not found: " .. tostring(params.role))
    end
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
        -- Safely get module relation
        local ok_module, _ = pcall(function() permission:get_module() end)
        local ok_role, _ = pcall(function() permission:get_role() end)

        -- Add module_machine_name from the module relation
        if ok_module and permission.module then
            permission.module_machine_name = permission.module.machine_name
        else
            permission.module_machine_name = nil
        end

        -- Add role_name from the role relation
        if ok_role and permission.role then
            permission.role_name = permission.role.role_name
        end

        -- Clean up internal IDs
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

-- Batch update permissions for a role
-- This efficiently handles all module permissions in a single transaction
function PermissionQueries.batchUpdate(params)
    local roleName = params.role
    local permissionsData = params.permissions

    -- Get the role
    local role = RoleQueries.roleByName(roleName)
    if not role then
        error("Role not found: " .. tostring(roleName))
    end

    -- Get all existing permissions for this role
    local existingPerms = PermissionModel:select("where role_id = ?", role.id)
    local existingByModule = {}
    for _, perm in ipairs(existingPerms) do
        -- Get the module for this permission
        local module = ModuleModel:find({ id = perm.module_id })
        if module then
            existingByModule[module.machine_name] = perm
        end
    end

    local stats = {
        created = 0,
        updated = 0,
        deleted = 0
    }

    -- Process each module in the permissions data
    for moduleName, actions in pairs(permissionsData) do
        -- Get the module
        local module = ModuleModel:find({ machine_name = moduleName })
        if module then
            local permString = ""
            if type(actions) == "table" then
                permString = table.concat(actions, ",")
            elseif type(actions) == "string" then
                permString = actions
            end

            local existingPerm = existingByModule[moduleName]

            if permString ~= "" then
                if existingPerm then
                    -- Update existing permission
                    existingPerm:update({
                        permissions = permString,
                        updated_at = os.date("!%Y-%m-%d %H:%M:%S")
                    })
                    stats.updated = stats.updated + 1
                else
                    -- Create new permission
                    PermissionModel:create({
                        role_id = role.id,
                        module_id = module.id,
                        permissions = permString,
                        uuid = Global.generateUUID(),
                        created_at = os.date("!%Y-%m-%d %H:%M:%S"),
                        updated_at = os.date("!%Y-%m-%d %H:%M:%S")
                    })
                    stats.created = stats.created + 1
                end
            else
                -- Empty permissions - delete if exists
                if existingPerm then
                    existingPerm:delete()
                    stats.deleted = stats.deleted + 1
                end
            end

            -- Mark as processed
            existingByModule[moduleName] = nil
        end
    end

    -- Delete any remaining permissions that weren't in the update
    -- (modules that were removed from the role)
    for _, perm in pairs(existingByModule) do
        perm:delete()
        stats.deleted = stats.deleted + 1
    end

    return stats
end

return PermissionQueries