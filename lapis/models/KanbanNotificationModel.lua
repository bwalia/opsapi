local Model = require("lapis.db.model").Model

local KanbanNotificationModel = Model:extend("kanban_notifications", {
    timestamp = true,
    relations = {
        { "project", belongs_to = "KanbanProjectModel", key = "project_id" },
        { "task", belongs_to = "KanbanTaskModel", key = "task_id" }
    }
})

return KanbanNotificationModel
