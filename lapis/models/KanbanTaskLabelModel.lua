local Model = require("lapis.db.model").Model

local KanbanTaskLabels = Model:extend("kanban_task_labels", {
    timestamp = true,
    relations = {
        { "project", belongs_to = "KanbanProjectModel", key = "project_id" }
    }
})

return KanbanTaskLabels
