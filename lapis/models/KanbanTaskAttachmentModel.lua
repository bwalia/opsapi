local Model = require("lapis.db.model").Model

local KanbanTaskAttachments = Model:extend("kanban_task_attachments", {
    timestamp = true,
    relations = {
        { "task", belongs_to = "KanbanTaskModel", key = "task_id" }
    }
})

return KanbanTaskAttachments
