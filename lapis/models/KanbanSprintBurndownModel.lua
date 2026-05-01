local Model = require("lapis.db.model").Model

local KanbanSprintBurndownModel = Model:extend("kanban_sprint_burndown", {
    timestamp = true,
    relations = {
        { "sprint", belongs_to = "KanbanSprintModel", key = "sprint_id" }
    }
})

return KanbanSprintBurndownModel
