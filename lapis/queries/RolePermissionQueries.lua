local Global = require "helper.global"
local RolePermission = require "models.RolePermissionModel"
local RoleQueries = require "queries.RoleQueries"
local Json = require("cjson")

local RolePermissionQueries = {}

function RolePermissionQueries.addRolePermission(roleName, permissionId)
    local role = RoleQueries.roleByName(roleName)
    if role then
        local data = {
            role_id = role.id,
            permission_id = permissionId,
            uuid = Global.generateUUID()
        }
        return RolePermission:create(data)
    end
end

function RolePermissionQueries.deleteByUid(uId)
    local userRole = RolePermission:find({
        user_id = uId
    })
    if userRole then
        userRole:delete()
    end
end
function RolePermissionQueries.deleteByRid(uId)
    local userRole = RolePermission:find({
        role_id = uId
    })
    if userRole then
        userRole:delete()
    end
end

return RolePermissionQueries