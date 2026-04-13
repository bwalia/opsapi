local Model = require("lapis.db.model").Model

local KanbanTaskLabelLinks = Model:extend("kanban_task_label_links", {
    -- Note: timestamp = false because this is a link/junction table with only created_at
    -- Links are immutable - only created or deleted (soft delete via deleted_at)
    timestamp = false,
    relations = {
        { "task", belongs_to = "KanbanTaskModel", key = "task_id" },
        { "label", belongs_to = "KanbanTaskLabelModel", key = "label_id" }
    }
})

return KanbanTaskLabelLinks
