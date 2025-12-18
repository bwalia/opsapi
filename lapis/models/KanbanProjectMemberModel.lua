local Model = require("lapis.db.model").Model

local KanbanProjectMembers = Model:extend("kanban_project_members", {
    timestamp = true,
    relations = {
        { "project", belongs_to = "KanbanProjectModel", key = "project_id" }
    }
})

return KanbanProjectMembers
