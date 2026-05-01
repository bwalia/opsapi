local Model = require("lapis.db.model").Model

local KanbanTimeEntryModel = Model:extend("kanban_time_entries", {
    timestamp = true,
    relations = {
        { "task", belongs_to = "KanbanTaskModel", key = "task_id" }
    }
})

return KanbanTimeEntryModel
