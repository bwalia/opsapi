local Model = require("lapis.db.model").Model
local Json = require("cjson")
local Global = require "helper.global"

local Users = Model:extend("users", {
    timestamp = true
})
local UserModel = {}

function UserModel.create(userData)
    if userData.uuid == nil then
        userData.uuid = Global.generateUUID()
    end
    userData.password = Global.hashPassword(userData.password)
    return Users:create(userData, {
        returning = "*"
    })
end

function UserModel.all(params)
    local page, perPage, orderField, orderDir =
        params.page or 1, params.perPage or 10, params.orderBy or 'id', params.orderDir or 'desc'

    local paginated = Users:paginated("order by " .. orderField .. " " .. orderDir, {
        per_page = perPage
    })
    return paginated:get_page(page)
end

function UserModel.show(id)
    return Users:find({
        uuid = id
    })
end

function UserModel.update(id, params)
    local user = Users:find({
        uuid = id
    })
    params.id = user.id
    return user:update(params, {
        returning = "*"
    })
end

function UserModel.destroy(id)
    local user = Users:find({
        uuid = id
    })
    return user:delete()
end
return UserModel