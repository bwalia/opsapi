local Model = require("lapis.db.model").Model

local KanbanProjects = Model:extend("kanban_projects", {
    timestamp = true,
    relations = {
        { "namespace", belongs_to = "NamespaceModel", key = "namespace_id" },
        { "boards", has_many = "KanbanBoardModel", key = "project_id" },
        { "members", has_many = "KanbanProjectMemberModel", key = "project_id" },
        { "labels", has_many = "KanbanTaskLabelModel", key = "project_id" },
        { "sprints", has_many = "KanbanSprintModel", key = "project_id" }
    }
})

return KanbanProjects
