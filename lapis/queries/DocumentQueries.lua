local Global = require "helper.global"
local DocumentModel = require "models.DocumentModel"
local Validation = require "helper.validations"


local DocumentQueries = {}

function DocumentQueries.create(data)
    Validation.createDocument(data)
    if data.uuid == nil then
        data.uuid = Global.generateUUID()
    end
    return DocumentModel:create(data, {
        returning = "*"
    })
end

function DocumentQueries.all(params)
    local page, perPage, orderField, orderDir =
        params.page or 1, params.perPage or 10, params.orderBy or 'id', params.orderDir or 'desc'

    local paginated = DocumentModel:paginated("order by " .. orderField .. " " .. orderDir, {
        per_page = perPage,
        fields =
        'id as internal_id, uuid as id, tags, title, sub_title, status, meta_title, meta_description,meta_keywords, user_id,published_date,content,created_at,updated_at'
    })
    return {
        data = paginated:get_page(page),
        total = paginated:total_items()
    }
end

function DocumentQueries.show(id)
    local singleRecord = DocumentModel:find({
        uuid = id
    })
    if singleRecord then
        singleRecord.internal_id = singleRecord.id
        singleRecord.id = singleRecord.uuid
    end
    return singleRecord
end

function DocumentQueries.update(id, params)
    local record = DocumentModel:find({
        uuid = id
    })
    params.id = record.id
    return record:update(params, {
        returning = "*"
    })
end

function DocumentQueries.destroy(id)
    local record = DocumentModel:find({
        uuid = id
    })
    return record:delete()
end

function DocumentQueries.roleByName(name)
    return DocumentModel:find({
        role_name = tostring(name)
    })
end

return DocumentQueries
