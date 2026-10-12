local Model = require("lapis.db.model").Model

-- No `timestamp`: kanban_notifications has created_at only (set by KanbanNotificationQueries.create), no
-- updated_at, so a timestamped insert failed and no notification was ever stored.
local KanbanNotificationModel = Model:extend("kanban_notifications", {
    relations = {
        { "project", belongs_to = "KanbanProjectModel", key = "project_id" },
        { "task", belongs_to = "KanbanTaskModel", key = "task_id" }
    }
})

return KanbanNotificationModel
