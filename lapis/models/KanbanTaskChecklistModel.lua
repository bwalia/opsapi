local Model = require("lapis.db.model").Model

local KanbanTaskChecklists = Model:extend("kanban_task_checklists", {
    timestamp = true,
    relations = {
        { "task", belongs_to = "KanbanTaskModel", key = "task_id" },
        { "items", has_many = "KanbanChecklistItemModel", key = "checklist_id" }
    }
})

return KanbanTaskChecklists
