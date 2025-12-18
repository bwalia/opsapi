local Model = require("lapis.db.model").Model

local KanbanBoards = Model:extend("kanban_boards", {
    timestamp = true,
    relations = {
        { "project", belongs_to = "KanbanProjectModel", key = "project_id" },
        { "columns", has_many = "KanbanColumnModel", key = "board_id" },
        { "tasks", has_many = "KanbanTaskModel", key = "board_id" }
    }
})

return KanbanBoards
