local Global = require "helper.global"
local Groups = require "models.GroupModel"
local Validation = require "helper.validations"


local GroupQueries = {}

function GroupQueries.create(data)
    Validation.createGroup(data)
    if data.uuid == nil then
        data.uuid = Global.generateUUID()
    end
    return Groups:create(data, {
        returning = "*"
    })
end

function GroupQueries.all(params)
    local page, perPage, orderField, orderDir =
        params.page or 1, params.perPage or 10, params.orderBy or 'id', params.orderDir or 'desc'

    local paginated = Groups:paginated("order by " .. orderField .. " " .. orderDir, {
        per_page = perPage
    })
    return paginated:get_page(page)
end

function GroupQueries.show(id)
    return Groups:find({
        uuid = id
    })
end

function GroupQueries.update(id, params)
    local role = Groups:find({
        uuid = id
    })
    params.id = role.id
    return role:update(params, {
        returning = "*"
    })
end

function GroupQueries.destroy(id)
    local role = Groups:find({
        uuid = id
    })
    return role:delete()
end

return GroupQueries