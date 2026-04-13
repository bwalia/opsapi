local Model = require("lapis.db.model").Model

local KanbanTaskAttachments = Model:extend("kanban_task_attachments", {
    -- Note: timestamp = false because this table only has created_at (no updated_at)
    -- Attachments are immutable - only created or deleted
    timestamp = false,
    relations = {
        { "task", belongs_to = "KanbanTaskModel", key = "task_id" }
    }
})

return KanbanTaskAttachments
