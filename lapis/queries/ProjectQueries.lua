local cJson = require("cjson")
local Global = require "helper.global"
local UserRolesQueries = require "queries.UserRoleQueries"
local Projects = require "models.ProjectModel"
local RoleModel = require "models.RoleModel"
local Validation = require "helper.validations"

local ProjectQueries = {}

function ProjectQueries.create(params)
    local projectData = params
    -- Validate the project data
    Validation.createProject(projectData)
    local template = params.template
    projectData.template = nil
    if projectData.uuid == nil then
        projectData.uuid = Global.generateUUID()
    end

    local project = Projects:create(projectData, {
        returning = "*"
    })
    return { data = project }
end

function ProjectQueries.all(params)
    local page, perPage, orderField, orderDir =
        params.page or 1, params.perPage or 10, params.orderBy or 'id', params.orderDir or 'desc'

    local paginated = Projects:paginated("order by " .. orderField .. " " .. orderDir, {
        per_page = perPage,
        fields = "*"
    })

    -- Append the role into user object
    local projects, projectsTemp = paginated:get_page(page), {}
    if next(projects) ~= nil then
        for pIndex, project in ipairs(projects) do
            -- project:get_templates()
            -- for index, role in ipairs(project.roles) do
            --     local roleData = RoleModel:find(role.role_id)
            --     project.roles[index]["name"] = roleData.role_name
            -- end
            project.internal_id = project.id
            project.id = project.uuid
            table.insert(projectsTemp, project)
        end
    end
    return {
        data = projectsTemp,
        total = paginated:total_items()
    }
end

function ProjectQueries.show(id)
    local project = Projects:find({
        uuid = id
    })
    if project then
        -- project:get_templates()
        -- for index, role in ipairs(project.templates) do
        --     local roleData = RoleModel:find(role.role_id)
        --     project.templates[index]["name"] = roleData.role_name
        -- end
        -- project.password = nil
        project.internal_id = project.id
        project.id = project.uuid
        return project, ngx.HTTP_OK
    end
end

function ProjectQueries.update(id, params)
    local user = Projects:find({
        uuid = id
    })
    params.id = nil
    return user:update(params, {
        returning = "*"
    })
end

function ProjectQueries.destroy(id)
    local user = Projects:find({
        uuid = id
    })
    if user then
        UserRolesQueries.deleteByUid(user.id)
        return user:delete()
    end
end

return ProjectQueries
