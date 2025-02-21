local Global = require "helper.global"
local Templates = require "models.TemplateModel"
local Validation = require "helper.validations"
local ProjectTemplateQueries = require "queries.ProjectTemplateQueries"


local TemplateQueries = {}

function TemplateQueries.create(templateData)
    Validation.createTemplate(templateData)
    local projectId = templateData.project_id
    templateData.project_id = nil
    if templateData.uuid == nil then
        templateData.uuid = Global.generateUUID()
    end
    local record = Templates:create(templateData, {
        returning = "*"
    })

    if record then
        ProjectTemplateQueries.addProjectTemplate(projectId, record.id)
    end

    return { data = record }
end

function TemplateQueries.all(params)
    local page, perPage, orderField, orderDir =
        params.page or 1, params.perPage or 10, params.orderBy or 'id', params.orderDir or 'desc'

    local paginated = Templates:paginated("order by " .. orderField .. " " .. orderDir, {
        per_page = perPage,
        fields =
        'id as internal_id, uuid as id, code, template_content, template_type, description, created_at, updated_at'
    })
    return {
        data = paginated:get_page(page),
        total = paginated:total_items()
    }
end

function TemplateQueries.show(id)
    local template = Templates:find({
        uuid = id
    })
    if template then
        template.internal_id = template.id
        template.id = template.uuid
    end
    return template
end

function TemplateQueries.update(id, params)
    local template = Templates:find({
        uuid = id
    })
    params.id = template.id
    return template:update(params, {
        returning = "*"
    })
end

function TemplateQueries.destroy(id)
    local template = Templates:find({
        uuid = id
    })
    return template:delete()
end

-- function TemplateQueries.tempByName(name)
--     return Templates:find({
--         role_name = tostring(name)
--     })
-- end

return TemplateQueries
