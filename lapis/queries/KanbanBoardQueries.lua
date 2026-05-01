--[[
    Kanban Board Queries
    ====================

    Query helpers for board and column operations within projects.
]]

local KanbanBoardModel = require "models.KanbanBoardModel"
local KanbanColumnModel = require "models.KanbanColumnModel"
local Global = require "helper.global"
local db = require("lapis.db")

local KanbanBoardQueries = {}

--------------------------------------------------------------------------------
-- Board CRUD Operations
--------------------------------------------------------------------------------

--- Create a new board
-- @param params table Board parameters
-- @return table|nil Created board
function KanbanBoardQueries.create(params)
    if not params.uuid then
        params.uuid = Global.generateUUID()
    end

    params.created_at = db.raw("NOW()")
    params.updated_at = db.raw("NOW()")

    -- Get next position
    if not params.position then
        local pos_result = db.query([[
            SELECT COALESCE(MAX(position), -1) + 1 as next_pos
            FROM kanban_boards WHERE project_id = ? AND archived_at IS NULL
        ]], params.project_id)
        params.position = pos_result[1].next_pos
    end

    local board = KanbanBoardModel:create(params, { returning = "*" })

    -- Create default columns if requested
    if board and params.create_default_columns then
        local default_columns = {
            { name = "Backlog", position = 0, color = "#6B7280" },
            { name = "To Do", position = 1, color = "#3B82F6" },
            { name = "In Progress", position = 2, color = "#F59E0B" },
            { name = "Review", position = 3, color = "#8B5CF6" },
            { name = "Done", position = 4, color = "#10B981", is_done_column = true, auto_close_tasks = true }
        }

        for _, col in ipairs(default_columns) do
            KanbanColumnModel:create({
                uuid = Global.generateUUID(),
                board_id = board.id,
                name = col.name,
                position = col.position,
                color = col.color,
                is_done_column = col.is_done_column or false,
                auto_close_tasks = col.auto_close_tasks or false,
                created_at = db.raw("NOW()"),
                updated_at = db.raw("NOW()")
            })
        end
    end

    return board
end

--- Get all boards for a project
-- @param project_id number Project ID
-- @param include_archived boolean Include archived boards
-- @return table[] Boards
function KanbanBoardQueries.getByProject(project_id, include_archived)
    local where_clause = "project_id = ?"
    if not include_archived then
        where_clause = where_clause .. " AND archived_at IS NULL"
    end

    local sql = string.format([[
        SELECT b.*,
               (SELECT COUNT(*) FROM kanban_columns WHERE board_id = b.id) as column_count,
               (SELECT COUNT(*) FROM kanban_tasks WHERE board_id = b.id AND archived_at IS NULL) as task_count
        FROM kanban_boards b
        WHERE %s
        ORDER BY b.position ASC
    ]], where_clause)

    return db.query(sql, project_id)
end

--- Get single board with columns
-- @param uuid string Board UUID
-- @return table|nil Board with columns
function KanbanBoardQueries.show(uuid)
    local sql = [[
        SELECT b.*,
               kp.uuid as project_uuid,
               kp.name as project_name,
               kp.namespace_id
        FROM kanban_boards b
        INNER JOIN kanban_projects kp ON kp.id = b.project_id
        WHERE b.uuid = ?
    ]]

    local result = db.query(sql, uuid)
    if not result or #result == 0 then
        return nil
    end

    local board = result[1]

    -- Get columns with task counts
    local columns_sql = [[
        SELECT c.*,
               (SELECT COUNT(*) FROM kanban_tasks WHERE column_id = c.id AND archived_at IS NULL) as task_count
        FROM kanban_columns c
        WHERE c.board_id = ?
        ORDER BY c.position ASC
    ]]
    board.columns = db.query(columns_sql, board.id)

    return board
end

--- Get board by ID
-- @param id number Board ID
-- @return table|nil Board
function KanbanBoardQueries.getById(id)
    return KanbanBoardModel:find({ id = id })
end

--- Update board
-- @param uuid string Board UUID
-- @param params table Update parameters
-- @return table|nil Updated board
function KanbanBoardQueries.update(uuid, params)
    local board = KanbanBoardModel:find({ uuid = uuid })
    if not board then return nil end

    params.updated_at = db.raw("NOW()")
    return board:update(params, { returning = "*" })
end

--- Archive board
-- @param uuid string Board UUID
-- @return table|nil Archived board
function KanbanBoardQueries.archive(uuid)
    local board = KanbanBoardModel:find({ uuid = uuid })
    if not board then return nil end

    return board:update({
        archived_at = db.raw("NOW()"),
        updated_at = db.raw("NOW()")
    }, { returning = "*" })
end

--- Delete board (hard delete)
-- @param uuid string Board UUID
-- @return boolean Success
function KanbanBoardQueries.destroy(uuid)
    local board = KanbanBoardModel:find({ uuid = uuid })
    if not board then return false end
    return board:delete()
end

--- Reorder boards
-- @param project_id number Project ID
-- @param board_positions table Array of { uuid, position }
-- @return boolean Success
function KanbanBoardQueries.reorder(project_id, board_positions)
    for _, item in ipairs(board_positions) do
        db.query([[
            UPDATE kanban_boards
            SET position = ?, updated_at = NOW()
            WHERE uuid = ? AND project_id = ?
        ]], item.position, item.uuid, project_id)
    end
    return true
end

--------------------------------------------------------------------------------
-- Column CRUD Operations
--------------------------------------------------------------------------------

--- Create a new column
-- @param params table Column parameters
-- @return table|nil Created column
function KanbanBoardQueries.createColumn(params)
    if not params.uuid then
        params.uuid = Global.generateUUID()
    end

    params.created_at = db.raw("NOW()")
    params.updated_at = db.raw("NOW()")

    -- Get next position
    if not params.position then
        local pos_result = db.query([[
            SELECT COALESCE(MAX(position), -1) + 1 as next_pos
            FROM kanban_columns WHERE board_id = ?
        ]], params.board_id)
        params.position = pos_result[1].next_pos
    end

    return KanbanColumnModel:create(params, { returning = "*" })
end

--- Get column by UUID
-- @param uuid string Column UUID
-- @return table|nil Column
function KanbanBoardQueries.getColumn(uuid)
    local sql = [[
        SELECT c.*,
               b.uuid as board_uuid,
               b.project_id,
               (SELECT COUNT(*) FROM kanban_tasks WHERE column_id = c.id AND archived_at IS NULL) as task_count
        FROM kanban_columns c
        INNER JOIN kanban_boards b ON b.id = c.board_id
        WHERE c.uuid = ?
    ]]
    local result = db.query(sql, uuid)
    return result and result[1]
end

--- Get column by ID
-- @param id number Column ID
-- @return table|nil Column
function KanbanBoardQueries.getColumnById(id)
    return KanbanColumnModel:find({ id = id })
end

--- Update column
-- @param uuid string Column UUID
-- @param params table Update parameters
-- @return table|nil Updated column
function KanbanBoardQueries.updateColumn(uuid, params)
    local column = KanbanColumnModel:find({ uuid = uuid })
    if not column then return nil end

    params.updated_at = db.raw("NOW()")
    return column:update(params, { returning = "*" })
end

--- Delete column
-- @param uuid string Column UUID
-- @return boolean Success
function KanbanBoardQueries.deleteColumn(uuid)
    local column = KanbanColumnModel:find({ uuid = uuid })
    if not column then return false end

    -- Move tasks to first column before deleting
    local first_column = db.query([[
        SELECT id FROM kanban_columns
        WHERE board_id = ? AND id != ?
        ORDER BY position ASC LIMIT 1
    ]], column.board_id, column.id)

    if first_column and #first_column > 0 then
        db.query([[
            UPDATE kanban_tasks
            SET column_id = ?, updated_at = NOW()
            WHERE column_id = ?
        ]], first_column[1].id, column.id)
    end

    return column:delete()
end

--- Reorder columns
-- @param board_id number Board ID
-- @param column_positions table Array of { uuid, position }
-- @return boolean Success
function KanbanBoardQueries.reorderColumns(board_id, column_positions)
    for _, item in ipairs(column_positions) do
        db.query([[
            UPDATE kanban_columns
            SET position = ?, updated_at = NOW()
            WHERE uuid = ? AND board_id = ?
        ]], item.position, item.uuid, board_id)
    end
    return true
end

--------------------------------------------------------------------------------
-- Board Statistics
--------------------------------------------------------------------------------

--- Get board statistics
-- @param board_id number Board ID
-- @return table Statistics
function KanbanBoardQueries.getStats(board_id)
    local sql = [[
        SELECT
            COUNT(*) as total_tasks,
            COUNT(*) FILTER (WHERE t.status = 'completed') as completed_tasks,
            COUNT(*) FILTER (WHERE t.status = 'in_progress') as in_progress_tasks,
            COUNT(*) FILTER (WHERE t.due_date < CURRENT_DATE AND t.status NOT IN ('completed', 'cancelled')) as overdue_tasks,
            COALESCE(SUM(t.story_points), 0) as total_story_points,
            COALESCE(SUM(t.story_points) FILTER (WHERE t.status = 'completed'), 0) as completed_story_points
        FROM kanban_tasks t
        WHERE t.board_id = ? AND t.archived_at IS NULL
    ]]

    local result = db.query(sql, board_id)
    return result and result[1] or {
        total_tasks = 0,
        completed_tasks = 0,
        in_progress_tasks = 0,
        overdue_tasks = 0,
        total_story_points = 0,
        completed_story_points = 0
    }
end

--- Get board with all columns and tasks (full board view)
-- @param uuid string Board UUID
-- @return table|nil Complete board data
function KanbanBoardQueries.getFullBoard(uuid)
    local board = KanbanBoardQueries.show(uuid)
    if not board then return nil end

    -- Get tasks for each column
    for _, column in ipairs(board.columns or {}) do
        local tasks_sql = [[
            SELECT t.*,
                   (SELECT json_agg(json_build_object('user_uuid', ta.user_uuid, 'assigned_at', ta.assigned_at))
                    FROM kanban_task_assignees ta WHERE ta.task_id = t.id) as assignees,
                   (SELECT json_agg(json_build_object('id', l.id, 'name', l.name, 'color', l.color))
                    FROM kanban_task_labels l
                    JOIN kanban_task_label_links ll ON ll.label_id = l.id
                    WHERE ll.task_id = t.id) as labels
            FROM kanban_tasks t
            WHERE t.column_id = ? AND t.archived_at IS NULL AND t.parent_task_id IS NULL
            ORDER BY t.position ASC
        ]]
        column.tasks = db.query(tasks_sql, column.id)
    end

    return board
end

return KanbanBoardQueries
