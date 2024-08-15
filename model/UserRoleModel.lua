local Model = require("lapis.db.model").Model
local RoleModel = require "model.RoleModel"
local Global = require "helper.global"
local Json = require("cjson")
local UserRoles = Model:extend("user__roles", {
    timestamp = true
})
local UserRolesModel = {}

function UserRolesModel.addRole(userId, roleName)
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

return UserRolesModel