local Global = require "helper.global"
local DocumentModel = require "models.DocumentModel"
local Validation = require "helper.validations"
local UserQueries = require "queries.UserQueries"
local DocumentTagsModel = require "models.DocumentTagsModel"
local TagsModel = require "models.TagsModel"
local ImageModel = require "models.ImageModel"
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
    local file = data.cover_image
    if not file then
        return {
            status = 400,
            json = {
                error = "Missing file"
            }
        }
    end

    local filename = file.filename or ("upload_" .. tostring(os.time()) .. ".bin")
    local url, err = Global.uploadToMinio(file, filename)

    if not url then
        return {
            data = {
                error = err
            }
        }
    end

    local selectedTags = data.tags
    local tagNames = data.tag_names
    local coverImg = data.cover_image
    data.tags = nil
    data.tag_names = nil
    data.cover_image = nil
    if data.status == "true" then
        data.published_date = os.date("%Y-%m-%d %H:%M:%S")
    end
    local savedDocument = DocumentModel:create(data, {
        returning = "*"
    })
    if savedDocument and coverImg then
        local imgUuid = Global.generateUUID()
        ImageModel:create({
            uuid = imgUuid,
            document_id = savedDocument.id,
            url = url,
            is_cover = true
        })
    end
    if selectedTags ~= nil then
        local tagUuids = Global.splitStr(selectedTags, ",")
        for _, tagUuid in ipairs(tagUuids) do
            local tag = TagsModel:find({
                uuid = tagUuid
            })
            if tag then
                local relUuid = Global.generateUUID()
                DocumentTagsModel:create({
                    document_id = savedDocument.id,
                    tag_id = tag.id,
                    uuid = relUuid
                })
            end
        end
        savedDocument.tags = selectedTags
    end

    if tagNames ~= nil and selectedTags == nil then
        local enteredTags = Global.splitStr(tagNames, ",")
        local tagUuids = {}

        for _, name in ipairs(enteredTags) do
            local trimmed = name:match("^%s*(.-)%s*$") -- trim spaces
            local tag = TagsModel:find({
                name = trimmed
            })

            if not tag then
                local newTagUuid = Global.generateUUID()
                tag = TagsModel:create({
                    uuid = newTagUuid,
                    name = trimmed
                })
            end

            if tag then
                local relUuid = Global.generateUUID()
                DocumentTagsModel:create({
                    document_id = savedDocument.id,
                    tag_id = tag.id,
                    uuid = relUuid
                })
                table.insert(tagUuids, tag.uuid)
            end
        end
        savedDocument.tags = table.concat(tagUuids, ",")
    end

    return {
        data = savedDocument
    }
end

function DocumentQueries.all(params)
    local page, perPage, orderField, orderDir = params.page or 1, params.perPage or 10, params.orderBy or 'id',
        params.orderDir or 'desc'

    local paginated = DocumentModel:paginated("order by " .. orderField .. " " .. orderDir, {
        per_page = perPage
    })

    local documents, updatedRecords = paginated:get_page(page), {}
    for _, document in ipairs(documents) do
        document:get_images()
        document:get_tags()
        document:get_user()
        for index, tag in ipairs(document.tags) do
            local tagUUID = tag.tag_id
            local tagData = TagsModel:find(tagUUID)
            document.tags[index]["name"] = tagData.name
        end
        document.internal_id = document.id
        document.id = document.uuid
        -- document['tags_data'] = tagRows
        table.insert(updatedRecords, document)
    end

    return {
        data = updatedRecords,
        total = paginated:total_items()
    }
end

function DocumentQueries.allData()
    local data = DocumentModel:select()

    local documents, updatedRecords = data, {}
    for _, document in ipairs(documents) do
        document:get_images()
        document:get_tags()
        document:get_user()
        for index, tag in ipairs(document.tags) do
            local tagUUID = tag.tag_id
            local tagData = TagsModel:find(tagUUID)
            document.tags[index]["name"] = tagData.name
        end
        document.internal_id = document.id
        document.id = document.uuid
        -- document['tags_data'] = tagRows
        table.insert(updatedRecords, document)
    end

    return {
        data = updatedRecords,
    }
end

function DocumentQueries.show(id)
    local singleRecord = DocumentModel:find({
        uuid = id
    })
    if singleRecord then
        singleRecord:get_images()
        singleRecord:get_user()
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

function DocumentQueries.deleteMultiple(params)
    local ids = cJson.decode(params.ids)
    local deleteAble = DocumentModel:find_all(ids.id, "uuid")
    if deleteAble then
        for _, record in ipairs(deleteAble) do
            record:delete()
        end
    end
    return {
        data = deleteAble
    }
end

function DocumentQueries.roleByName(name)
    return DocumentModel:find({
        role_name = tostring(name)
    })
end

return DocumentQueries
