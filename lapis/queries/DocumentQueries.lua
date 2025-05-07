local Global = require "helper.global"
local DocumentModel = require "models.DocumentModel"
local Validation = require "helper.validations"
local UserQueries = require "queries.UserQueries"
local DocumentTagsModel = require "models.DocumentTagsModel"
local TagsModel = require "models.TagsModel"
local cJson = require "cjson"
local db = require("lapis.db")

local DocumentQueries = {}

function DocumentQueries.create(data)
    Validation.createDocument(data)
    if data.uuid == nil then
        data.uuid = Global.generateUUID()
    end
    local userUuid = data.user_id
    local user = UserQueries.show(userUuid)
    if user ~= nil then
        data.user_id = user.internal_id
    else
        data.user_id = 1
    end
    local selectedTags = data.tags
    data.tags = nil
    if data.status == "true" then
        data.published_date = os.date("%Y-%m-%d %H:%M:%S")
    end
    local savedDocument = DocumentModel:create(data, {
        returning = "*"
    })
    if selectedTags ~= nil then
        local tags = Global.splitStr(selectedTags, ",")
        for _, name in ipairs(tags) do
            local tag = TagsModel:find({ uuid = name })
            if tag then
                local relUuid = Global.generateUUID()
                tag = DocumentTagsModel:create({ document_id = savedDocument.id, tag_id = tag.id, uuid = relUuid })
            end
        end
        savedDocument.tags = selectedTags
    end
    return {data = savedDocument}
end

function DocumentQueries.all(params)
    local page, perPage, orderField, orderDir =
        params.page or 1, params.perPage or 10, params.orderBy or 'id', params.orderDir or 'desc'

    local paginated = DocumentModel:paginated("order by " .. orderField .. " " .. orderDir, {
        per_page = perPage,
        fields =
        'id as internal_id, uuid as id, title, sub_title, slug, status, meta_title, meta_description,meta_keywords, user_id,published_date,content,created_at,updated_at'
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
        local tagRows = db.select([[
            t.id as internal_id, t.uuid as id, t.name
            FROM tags t
            INNER JOIN document__tags dt ON dt.tag_id = t.id
            WHERE dt.document_id = ?
          ]], singleRecord.id)
        local tagIds = {}
        for _, tag in ipairs(tagRows) do
            table.insert(tagIds, tag.id)
            singleRecord.tags = tagIds
        end
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
