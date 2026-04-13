local Global = require "helper.global"
local ProjectTemplate = require "models.ProjectTemplateModel"
local RoleQueries = require "queries.RoleQueries"
local cJson = require "cjson"

local ProjectTemplateQueries = {}

function ProjectTemplateQueries.addTemplate(userId, templateName)
    local template = RoleQueries.roleByName(templateName)
    if template then
        local data = {
            project_id = userId,
            template_id = template.id,
            uuid = Global.generateUUID()
        }
        return ProjectTemplate:create(data)
    else
        return nil
    end
end

function ProjectTemplateQueries.addProjectTemplate(pId, tId)
    if pId and tId then
        local data = {
            project_id = pId,
            template_id = tId,
            uuid = Global.generateUUID()
        }
        return ProjectTemplate:create(data)
    else
        return nil
    end
end

function ProjectTemplateQueries.deleteByPid(pId)
    local projectTemplate = ProjectTemplate:find({
        project_id = pId
    })
    if projectTemplate then
        return projectTemplate:delete()
    end
end
function ProjectTemplateQueries.deleteByTid(tId)
    local projectTemplate = ProjectTemplate:find({
        template_id = tId
    })
    if projectTemplate then
        projectTemplate:delete()
    end
end

return ProjectTemplateQueries