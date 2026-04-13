local Model = require("lapis.db.model").Model

local KanbanNotificationPreferenceModel = Model:extend("kanban_notification_preferences", {
    timestamp = true,
    relations = {
        { "project", belongs_to = "KanbanProjectModel", key = "project_id" }
    }
})

return KanbanNotificationPreferenceModel
