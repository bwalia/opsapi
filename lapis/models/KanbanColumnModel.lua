local Model = require("lapis.db.model").Model

local KanbanColumns = Model:extend("kanban_columns", {
    timestamp = true,
    relations = {
        { "board", belongs_to = "KanbanBoardModel", key = "board_id" },
        { "tasks", has_many = "KanbanTaskModel", key = "column_id" }
    }
})

return KanbanColumns
