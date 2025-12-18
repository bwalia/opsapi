local Model = require("lapis.db.model").Model

local KanbanTaskAssignees = Model:extend("kanban_task_assignees", {
    timestamp = true,
    relations = {
        { "task", belongs_to = "KanbanTaskModel", key = "task_id" }
    }
})

return KanbanTaskAssignees
