local Model = require("lapis.db.model").Model

local KanbanTaskActivities = Model:extend("kanban_task_activities", {
    -- Note: timestamp = false because this table is an audit log and only has created_at
    -- No updated_at column - activity records are immutable once created
    timestamp = false,
    relations = {
        { "task", belongs_to = "KanbanTaskModel", key = "task_id" }
    }
})

return KanbanTaskActivities
