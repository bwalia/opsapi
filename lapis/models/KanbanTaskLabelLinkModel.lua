local Model = require("lapis.db.model").Model

local KanbanTaskLabelLinks = Model:extend("kanban_task_label_links", {
    timestamp = true,
    relations = {
        { "task", belongs_to = "KanbanTaskModel", key = "task_id" },
        { "label", belongs_to = "KanbanTaskLabelModel", key = "label_id" }
    }
})

return KanbanTaskLabelLinks
