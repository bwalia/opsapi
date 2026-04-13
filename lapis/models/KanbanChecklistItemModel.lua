local Model = require("lapis.db.model").Model

local KanbanChecklistItems = Model:extend("kanban_checklist_items", {
    timestamp = true,
    relations = {
        { "checklist", belongs_to = "KanbanTaskChecklistModel", key = "checklist_id" }
    }
})

return KanbanChecklistItems
