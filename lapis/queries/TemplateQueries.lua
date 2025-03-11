local Global = require "helper.global"
local Templates = require "models.TemplateModel"
local Validation = require "helper.validations"
local ProjectTemplate = require "queries.ProjectTemplateQueries"
local Project = require "queries.ProjectQueries"
local cJson = require "cjson"


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
        local project = Project.show(projectId)
        if project then
            ProjectTemplate.addProjectTemplate(project.internal_id, record.id)
        end
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
        template:get_projects()
        template.project_ids = {}
        for index, tempProject in ipairs(template.projects) do
            local project = Project.showByInternalId(tempProject.project_id)
            if project then
                template.projects[index] = project
            end
        end
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
    if params.data and params.data ~= nil and type(params.data) == "string" then
        local reqData = cJson.decode(params.data)
        if reqData.projects and type(reqData.projects) == "table" then
            ProjectTemplate.deleteByTid(template.id)
            for index, pUuid in ipairs(reqData.projects) do
                local project = Project.show(pUuid)
                ProjectTemplate.addProjectTemplate(project.internal_id, template.id)
            end
        end
        local tempData = {
            code = reqData.code,
            template_content = reqData.template_content,
            template_type = reqData.template_type,
            description = reqData.description
        }
        local updateData = template:update(tempData, {
            returning = "*"
        })
        return { data = updateData }
    end
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
