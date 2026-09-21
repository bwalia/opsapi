local Model = require("lapis.db.model").Model

local KanbanEpics = Model:extend("kanban_epics", {
    timestamp = true,
    relations = {
        { "project", belongs_to = "KanbanProjectModel", key = "project_id" },
        { "tasks",   has_many = "KanbanTaskModel",      key = "epic_id" }
    }
})

return KanbanEpics
