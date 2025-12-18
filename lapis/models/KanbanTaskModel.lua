local Model = require("lapis.db.model").Model

local KanbanTasks = Model:extend("kanban_tasks", {
    timestamp = true,
    relations = {
        { "board", belongs_to = "KanbanBoardModel", key = "board_id" },
        { "column", belongs_to = "KanbanColumnModel", key = "column_id" },
        { "parent_task", belongs_to = "KanbanTaskModel", key = "parent_task_id" },
        { "sprint", belongs_to = "KanbanSprintModel", key = "sprint_id" },
        { "assignees", has_many = "KanbanTaskAssigneeModel", key = "task_id" },
        { "comments", has_many = "KanbanTaskCommentModel", key = "task_id" },
        { "attachments", has_many = "KanbanTaskAttachmentModel", key = "task_id" },
        { "checklists", has_many = "KanbanTaskChecklistModel", key = "task_id" },
        { "activities", has_many = "KanbanTaskActivityModel", key = "task_id" },
        { "subtasks", has_many = "KanbanTaskModel", key = "parent_task_id" }
    }
})

return KanbanTasks
