local Model = require("lapis.db.model").Model

local KanbanTaskAssignees = Model:extend("kanban_task_assignees", {
    -- Note: timestamp = false because this table doesn't have updated_at column
    -- Only has: id, uuid, task_id, user_uuid, assigned_by, assigned_at, created_at, deleted_at
    timestamp = false,
    relations = {
        { "task", belongs_to = "KanbanTaskModel", key = "task_id" }
    }
})

return KanbanTaskAssignees
