local RoleModel = require "models.RoleModel"
local Global = require "helper.global"
local Json = require("cjson")
local UserRoles = require "models.UserRoleModel"

local UserRolesQueries = {}

function UserRolesQueries.addRole(userId, roleName)
    local role = RoleModel.roleByName(roleName)
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