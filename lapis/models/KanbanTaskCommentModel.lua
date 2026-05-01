local Model = require("lapis.db.model").Model

local KanbanTaskComments = Model:extend("kanban_task_comments", {
    timestamp = true,
    relations = {
        { "task", belongs_to = "KanbanTaskModel", key = "task_id" },
        { "parent_comment", belongs_to = "KanbanTaskCommentModel", key = "parent_comment_id" },
        { "replies", has_many = "KanbanTaskCommentModel", key = "parent_comment_id" }
    }
})

return KanbanTaskComments
