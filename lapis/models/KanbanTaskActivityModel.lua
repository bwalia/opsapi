local Model = require("lapis.db.model").Model

local KanbanTaskActivities = Model:extend("kanban_task_activities", {
    timestamp = true,
    relations = {
        { "task", belongs_to = "KanbanTaskModel", key = "task_id" }
    }
})

return KanbanTaskActivities
