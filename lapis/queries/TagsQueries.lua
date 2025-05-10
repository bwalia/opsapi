local Global = require "helper.global"
local TagsModel = require "models.TagsModel"
local Validation = require "helper.validations"


local TagsQueries = {}

function TagsQueries.create(data)
    Validation.createTag(data)
    if data.uuid == nil then
        data.uuid = Global.generateUUID()
    end
    local tag = TagsModel:create(data, {
        returning = "*"
    })
    return {data = tag}
end

function TagsQueries.all(params)
    local page, perPage, orderField, orderDir =
        params.page or 1, params.perPage or 10, params.orderBy or 'id', params.orderDir or 'desc'

    local paginated = TagsModel:paginated("order by " .. orderField .. " " .. orderDir, {
        per_page = perPage,
        fields = 'id as internal_id, uuid as id, name, created_at, updated_at'
    })
    return {
        data = paginated:get_page(page),
        total = paginated:total_items()
    }
end

function TagsQueries.show(id)
    local record = TagsModel:find({
        uuid = id
    })
    if record then
        record.internal_id = record.id
        record.id = record.uuid
    end
    return record
end

function TagsQueries.update(id, params)
    local role = TagsModel:find({
        uuid = id
    })
    params.id = role.id
    return role:update(params, {
        returning = "*"
    })
end

function TagsQueries.destroy(id)
    local role = TagsModel:find({
        uuid = id
    })
    return role:delete()
end

function TagsQueries.roleByName(name)
    return TagsModel:find({
        role_name = tostring(name)
    })
end

return TagsQueries