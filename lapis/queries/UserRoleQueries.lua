local Global = require "helper.global"
local UserRoles = require "models.UserRoleModel"
local RoleQueries = require "queries.RoleQueries"

local UserRolesQueries = {}

function UserRolesQueries.addRole(userId, roleName)
    local role = RoleQueries.roleByName(roleName)
    if role then
        local data = {
            user_id = userId,
            role_id = role.id,
            uuid = Global.generateUUID()
        }
        return UserRoles:create(data)
    else
        return nil
    end
end

return UserRolesQueries