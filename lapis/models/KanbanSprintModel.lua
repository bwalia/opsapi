local Model = require("lapis.db.model").Model

local KanbanSprints = Model:extend("kanban_sprints", {
    timestamp = true,
    relations = {
        { "project", belongs_to = "KanbanProjectModel", key = "project_id" },
        { "board", belongs_to = "KanbanBoardModel", key = "board_id" },
        { "tasks", has_many = "KanbanTaskModel", key = "sprint_id" }
    }
})

return KanbanSprints
