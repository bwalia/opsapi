--[[
    Kanban Sprint Queries
    =====================

    Sprint management for agile project management:
    - Sprint CRUD operations
    - Task-sprint linking
    - Burndown chart data
    - Velocity tracking
    - Sprint retrospectives
]]

local KanbanSprintModel = require "models.KanbanSprintModel"
local KanbanSprintBurndownModel = require "models.KanbanSprintBurndownModel"
local KanbanTaskModel = require "models.KanbanTaskModel"
local Global = require "helper.global"
local db = require("lapis.db")
local cjson = require("cjson.safe")

local KanbanSprintQueries = {}

--------------------------------------------------------------------------------
-- Sprint CRUD Operations
--------------------------------------------------------------------------------

--- Create a new sprint
-- @param params table Sprint parameters
-- @return table|nil Created sprint or nil
function KanbanSprintQueries.create(params)
    if not params.uuid then
        params.uuid = Global.generateUUID()
    end

    -- Validate project exists
    local project = db.query("SELECT id FROM kanban_projects WHERE id = ?", params.project_id)
    if not project or #project == 0 then
        return nil, "Project not found"
    end

    params.status = params.status or "planned"
    params.created_at = db.raw("NOW()")
    params.updated_at = db.raw("NOW()")

    local sprint = KanbanSprintModel:create(params, { returning = "*" })

    if sprint then
        ngx.log(ngx.INFO, "[Sprint] Created: ", sprint.uuid, " for project: ", params.project_id)
    end

    return sprint
end

--- Get sprint by UUID
-- @param uuid string Sprint UUID
-- @return table|nil Sprint with stats
function KanbanSprintQueries.show(uuid)
    local sql = [[
        SELECT s.*,
               p.name as project_name,
               p.uuid as project_uuid,
               b.name as board_name,
               b.uuid as board_uuid
        FROM kanban_sprints s
        INNER JOIN kanban_projects p ON p.id = s.project_id
        LEFT JOIN kanban_boards b ON b.id = s.board_id
        WHERE s.uuid = ? AND s.deleted_at IS NULL
    ]]

    local result = db.query(sql, uuid)
    if not result or #result == 0 then
        return nil
    end

    local sprint = result[1]

    -- Get task stats
    local stats = db.query([[
        SELECT
            COUNT(*) as total_tasks,
            SUM(CASE WHEN status = 'completed' THEN 1 ELSE 0 END) as completed_tasks,
            SUM(COALESCE(story_points, 0)) as total_points,
            SUM(CASE WHEN status = 'completed' THEN COALESCE(story_points, 0) ELSE 0 END) as completed_points
        FROM kanban_tasks
        WHERE sprint_id = ? AND deleted_at IS NULL AND archived_at IS NULL
    ]], sprint.id)

    if stats and #stats > 0 then
        sprint.total_tasks = tonumber(stats[1].total_tasks) or 0
        sprint.completed_tasks = tonumber(stats[1].completed_tasks) or 0
        sprint.total_points = tonumber(stats[1].total_points) or 0
        sprint.completed_points = tonumber(stats[1].completed_points) or 0
    end

    return sprint
end

--- Get sprint by ID
-- @param id number Sprint ID
-- @return table|nil Sprint
function KanbanSprintQueries.getById(id)
    return KanbanSprintModel:find({ id = id })
end

--- Get sprints for a project
-- @param project_id number Project ID
-- @param params table Filter parameters
-- @return table { data, total }
function KanbanSprintQueries.getByProject(project_id, params)
    params = params or {}
    local page = params.page or 1
    local perPage = params.perPage or 20
    local offset = (page - 1) * perPage

    local where_clauses = { "s.project_id = ?", "s.deleted_at IS NULL" }
    local where_values = { project_id }

    if params.status then
        table.insert(where_clauses, "s.status = ?")
        table.insert(where_values, params.status)
    end

    if params.board_id then
        table.insert(where_clauses, "s.board_id = ?")
        table.insert(where_values, params.board_id)
    end

    local where_sql = table.concat(where_clauses, " AND ")

    local sql = string.format([[
        SELECT s.*,
               b.name as board_name,
               (SELECT COUNT(*) FROM kanban_tasks WHERE sprint_id = s.id AND deleted_at IS NULL) as task_count,
               (SELECT COUNT(*) FROM kanban_tasks WHERE sprint_id = s.id AND status = 'completed' AND deleted_at IS NULL) as completed_count
        FROM kanban_sprints s
        LEFT JOIN kanban_boards b ON b.id = s.board_id
        WHERE %s
        ORDER BY
            CASE s.status
                WHEN 'active' THEN 1
                WHEN 'planned' THEN 2
                WHEN 'completed' THEN 3
                ELSE 4
            END,
            s.start_date DESC NULLS LAST
        LIMIT ? OFFSET ?
    ]], where_sql)

    table.insert(where_values, perPage)
    table.insert(where_values, offset)

    local sprints = db.query(sql, table.unpack(where_values))

    -- Count query
    local count_sql = string.format([[
        SELECT COUNT(*) as total FROM kanban_sprints s WHERE %s
    ]], where_sql)

    local count_values = {}
    for i = 1, #where_values - 2 do
        table.insert(count_values, where_values[i])
    end

    local count_result = db.query(count_sql, table.unpack(count_values))
    local total = count_result and count_result[1] and count_result[1].total or 0

    return {
        data = sprints,
        total = tonumber(total)
    }
end

--- Update a sprint
-- @param uuid string Sprint UUID
-- @param params table Update parameters
-- @return table|nil Updated sprint
function KanbanSprintQueries.update(uuid, params)
    local sprint = KanbanSprintModel:find({ uuid = uuid })
    if not sprint then
        return nil, "Sprint not found"
    end

    -- Handle retrospective JSON
    if params.retrospective and type(params.retrospective) == "table" then
        params.retrospective = cjson.encode(params.retrospective)
    end

    params.updated_at = db.raw("NOW()")

    return sprint:update(params, { returning = "*" })
end

--- Start a sprint
-- @param uuid string Sprint UUID
-- @return table|nil Started sprint
function KanbanSprintQueries.start(uuid)
    local sprint = KanbanSprintModel:find({ uuid = uuid })
    if not sprint then
        return nil, "Sprint not found"
    end

    if sprint.status ~= "planned" then
        return nil, "Only planned sprints can be started"
    end

    -- Check if there's already an active sprint for this project
    local active = db.query([[
        SELECT id FROM kanban_sprints
        WHERE project_id = ? AND status = 'active' AND deleted_at IS NULL AND id != ?
    ]], sprint.project_id, sprint.id)

    if active and #active > 0 then
        return nil, "There is already an active sprint for this project"
    end

    -- Calculate initial sprint stats
    local stats = db.query([[
        SELECT
            SUM(COALESCE(story_points, 0)) as total_points,
            COUNT(*) as task_count
        FROM kanban_tasks
        WHERE sprint_id = ? AND deleted_at IS NULL AND archived_at IS NULL
    ]], sprint.id)

    local total_points = stats and stats[1] and tonumber(stats[1].total_points) or 0
    local task_count = stats and stats[1] and tonumber(stats[1].task_count) or 0

    local updated = sprint:update({
        status = "active",
        start_date = sprint.start_date or db.raw("CURRENT_DATE"),
        total_points = total_points,
        task_count = task_count,
        updated_at = db.raw("NOW()")
    }, { returning = "*" })

    -- Create initial burndown data point
    if updated then
        KanbanSprintQueries.recordBurndown(sprint.id)
    end

    return updated
end

--- Complete a sprint
-- @param uuid string Sprint UUID
-- @param retrospective table|nil Retrospective data
-- @return table|nil Completed sprint
function KanbanSprintQueries.complete(uuid, retrospective)
    local sprint = KanbanSprintModel:find({ uuid = uuid })
    if not sprint then
        return nil, "Sprint not found"
    end

    if sprint.status ~= "active" then
        return nil, "Only active sprints can be completed"
    end

    -- Calculate final stats
    local stats = db.query([[
        SELECT
            SUM(CASE WHEN status = 'completed' THEN COALESCE(story_points, 0) ELSE 0 END) as completed_points,
            SUM(CASE WHEN status = 'completed' THEN 1 ELSE 0 END) as completed_count,
            COUNT(*) as total_count
        FROM kanban_tasks
        WHERE sprint_id = ? AND deleted_at IS NULL AND archived_at IS NULL
    ]], sprint.id)

    local completed_points = stats and stats[1] and tonumber(stats[1].completed_points) or 0
    local completed_count = stats and stats[1] and tonumber(stats[1].completed_count) or 0

    local update_params = {
        status = "completed",
        completed_at = db.raw("NOW()"),
        end_date = sprint.end_date or db.raw("CURRENT_DATE"),
        completed_points = completed_points,
        completed_task_count = completed_count,
        velocity = completed_points, -- Velocity is completed points
        updated_at = db.raw("NOW()")
    }

    if retrospective then
        update_params.retrospective = cjson.encode(retrospective)
    end

    return sprint:update(update_params, { returning = "*" })
end

--- Cancel a sprint
-- @param uuid string Sprint UUID
-- @return table|nil Cancelled sprint
function KanbanSprintQueries.cancel(uuid)
    local sprint = KanbanSprintModel:find({ uuid = uuid })
    if not sprint then
        return nil, "Sprint not found"
    end

    if sprint.status == "completed" then
        return nil, "Cannot cancel a completed sprint"
    end

    -- Remove tasks from sprint (move back to backlog)
    db.query([[
        UPDATE kanban_tasks
        SET sprint_id = NULL, updated_at = NOW()
        WHERE sprint_id = ? AND deleted_at IS NULL
    ]], sprint.id)

    return sprint:update({
        status = "cancelled",
        updated_at = db.raw("NOW()")
    }, { returning = "*" })
end

--- Delete a sprint (soft delete)
-- @param uuid string Sprint UUID
-- @return boolean Success
function KanbanSprintQueries.delete(uuid)
    local sprint = KanbanSprintModel:find({ uuid = uuid })
    if not sprint then
        return false, "Sprint not found"
    end

    if sprint.status == "active" then
        return false, "Cannot delete an active sprint. Cancel it first."
    end

    -- Remove tasks from sprint
    db.query([[
        UPDATE kanban_tasks
        SET sprint_id = NULL, updated_at = NOW()
        WHERE sprint_id = ? AND deleted_at IS NULL
    ]], sprint.id)

    sprint:update({
        deleted_at = db.raw("NOW()"),
        updated_at = db.raw("NOW()")
    })

    return true
end

--------------------------------------------------------------------------------
-- Task-Sprint Operations
--------------------------------------------------------------------------------

--- Add tasks to sprint
-- @param sprint_id number Sprint ID
-- @param task_ids table[] Task IDs
-- @return number Count of added tasks
function KanbanSprintQueries.addTasks(sprint_id, task_ids)
    if not task_ids or #task_ids == 0 then
        return 0
    end

    local count = 0
    for _, task_id in ipairs(task_ids) do
        local result = db.query([[
            UPDATE kanban_tasks
            SET sprint_id = ?, updated_at = NOW()
            WHERE id = ? AND deleted_at IS NULL AND archived_at IS NULL
        ]], sprint_id, task_id)

        if result and result.affected_rows and result.affected_rows > 0 then
            count = count + 1
        end
    end

    -- Update sprint task count
    db.query([[
        UPDATE kanban_sprints
        SET task_count = (
            SELECT COUNT(*) FROM kanban_tasks
            WHERE sprint_id = ? AND deleted_at IS NULL AND archived_at IS NULL
        ),
        total_points = (
            SELECT COALESCE(SUM(story_points), 0) FROM kanban_tasks
            WHERE sprint_id = ? AND deleted_at IS NULL AND archived_at IS NULL
        ),
        updated_at = NOW()
        WHERE id = ?
    ]], sprint_id, sprint_id, sprint_id)

    return count
end

--- Remove tasks from sprint
-- @param sprint_id number Sprint ID
-- @param task_ids table[] Task IDs
-- @return number Count of removed tasks
function KanbanSprintQueries.removeTasks(sprint_id, task_ids)
    if not task_ids or #task_ids == 0 then
        return 0
    end

    local count = 0
    for _, task_id in ipairs(task_ids) do
        local result = db.query([[
            UPDATE kanban_tasks
            SET sprint_id = NULL, updated_at = NOW()
            WHERE id = ? AND sprint_id = ? AND deleted_at IS NULL
        ]], task_id, sprint_id)

        if result and result.affected_rows and result.affected_rows > 0 then
            count = count + 1
        end
    end

    -- Update sprint task count
    db.query([[
        UPDATE kanban_sprints
        SET task_count = (
            SELECT COUNT(*) FROM kanban_tasks
            WHERE sprint_id = ? AND deleted_at IS NULL AND archived_at IS NULL
        ),
        total_points = (
            SELECT COALESCE(SUM(story_points), 0) FROM kanban_tasks
            WHERE sprint_id = ? AND deleted_at IS NULL AND archived_at IS NULL
        ),
        updated_at = NOW()
        WHERE id = ?
    ]], sprint_id, sprint_id, sprint_id)

    return count
end

--- Get tasks in a sprint
-- @param sprint_id number Sprint ID
-- @param params table Filter parameters
-- @return table { data, total }
function KanbanSprintQueries.getTasks(sprint_id, params)
    params = params or {}
    local page = params.page or 1
    local perPage = params.perPage or 50
    local offset = (page - 1) * perPage

    local sql = [[
        SELECT t.*,
               c.name as column_name,
               c.color as column_color
        FROM kanban_tasks t
        LEFT JOIN kanban_columns c ON c.id = t.column_id
        WHERE t.sprint_id = ? AND t.deleted_at IS NULL AND t.archived_at IS NULL
        ORDER BY t.priority DESC, t.position ASC
        LIMIT ? OFFSET ?
    ]]

    local tasks = db.query(sql, sprint_id, perPage, offset)

    local count_sql = [[
        SELECT COUNT(*) as total FROM kanban_tasks
        WHERE sprint_id = ? AND deleted_at IS NULL AND archived_at IS NULL
    ]]
    local count_result = db.query(count_sql, sprint_id)
    local total = count_result and count_result[1] and count_result[1].total or 0

    return {
        data = tasks,
        total = tonumber(total)
    }
end

--------------------------------------------------------------------------------
-- Burndown Chart Data
--------------------------------------------------------------------------------

--- Record a burndown data point for a sprint
-- @param sprint_id number Sprint ID
-- @return table|nil Created burndown record
function KanbanSprintQueries.recordBurndown(sprint_id)
    local sprint = KanbanSprintModel:find({ id = sprint_id })
    if not sprint or sprint.status ~= "active" then
        return nil
    end

    -- Get current task stats
    local stats = db.query([[
        SELECT
            COUNT(*) as total_tasks,
            SUM(CASE WHEN status = 'completed' THEN 1 ELSE 0 END) as completed_tasks,
            SUM(COALESCE(story_points, 0)) as total_points,
            SUM(CASE WHEN status = 'completed' THEN COALESCE(story_points, 0) ELSE 0 END) as completed_points
        FROM kanban_tasks
        WHERE sprint_id = ? AND deleted_at IS NULL AND archived_at IS NULL
    ]], sprint_id)

    if not stats or #stats == 0 then
        return nil
    end

    local total_tasks = tonumber(stats[1].total_tasks) or 0
    local completed_tasks = tonumber(stats[1].completed_tasks) or 0
    local total_points = tonumber(stats[1].total_points) or 0
    local completed_points = tonumber(stats[1].completed_points) or 0

    -- Calculate ideal remaining (linear burndown)
    local ideal_remaining = 0
    if sprint.start_date and sprint.end_date then
        local days_result = db.query([[
            SELECT
                (CURRENT_DATE - ?::date) as elapsed_days,
                (?::date - ?::date) as total_days
        ]], sprint.start_date, sprint.end_date, sprint.start_date)

        if days_result and #days_result > 0 then
            local elapsed = tonumber(days_result[1].elapsed_days) or 0
            local total_days = tonumber(days_result[1].total_days) or 1
            if total_days > 0 then
                local daily_rate = total_points / total_days
                ideal_remaining = math.max(0, total_points - (daily_rate * elapsed))
            end
        end
    end

    -- Upsert burndown record for today
    local existing = db.query([[
        SELECT id FROM kanban_sprint_burndown
        WHERE sprint_id = ? AND recorded_date = CURRENT_DATE
    ]], sprint_id)

    if existing and #existing > 0 then
        -- Update existing
        db.query([[
            UPDATE kanban_sprint_burndown SET
                total_points = ?,
                completed_points = ?,
                remaining_points = ?,
                total_tasks = ?,
                completed_tasks = ?,
                remaining_tasks = ?,
                ideal_remaining = ?
            WHERE sprint_id = ? AND recorded_date = CURRENT_DATE
        ]], total_points, completed_points, total_points - completed_points,
            total_tasks, completed_tasks, total_tasks - completed_tasks,
            ideal_remaining, sprint_id)

        return KanbanSprintBurndownModel:find({ id = existing[1].id })
    else
        -- Create new
        return KanbanSprintBurndownModel:create({
            sprint_id = sprint_id,
            recorded_date = db.raw("CURRENT_DATE"),
            total_points = total_points,
            completed_points = completed_points,
            remaining_points = total_points - completed_points,
            total_tasks = total_tasks,
            completed_tasks = completed_tasks,
            remaining_tasks = total_tasks - completed_tasks,
            ideal_remaining = ideal_remaining,
            created_at = db.raw("NOW()")
        }, { returning = "*" })
    end
end

--- Get burndown data for a sprint
-- @param sprint_id number Sprint ID
-- @return table[] Burndown data points
function KanbanSprintQueries.getBurndown(sprint_id)
    local sql = [[
        SELECT * FROM kanban_sprint_burndown
        WHERE sprint_id = ?
        ORDER BY recorded_date ASC
    ]]

    return db.query(sql, sprint_id)
end

--------------------------------------------------------------------------------
-- Velocity Tracking
--------------------------------------------------------------------------------

--- Get velocity history for a project
-- @param project_id number Project ID
-- @param limit number Number of sprints to include
-- @return table[] Velocity data
function KanbanSprintQueries.getVelocityHistory(project_id, limit)
    limit = limit or 10

    local sql = [[
        SELECT
            s.uuid,
            s.name,
            s.start_date,
            s.end_date,
            s.velocity,
            s.total_points,
            s.completed_points,
            s.task_count,
            s.completed_task_count
        FROM kanban_sprints s
        WHERE s.project_id = ? AND s.status = 'completed' AND s.deleted_at IS NULL
        ORDER BY s.completed_at DESC
        LIMIT ?
    ]]

    local sprints = db.query(sql, project_id, limit)

    -- Calculate average velocity
    local total_velocity = 0
    for _, sprint in ipairs(sprints) do
        total_velocity = total_velocity + (tonumber(sprint.velocity) or 0)
    end

    local avg_velocity = #sprints > 0 and (total_velocity / #sprints) or 0

    return {
        sprints = sprints,
        average_velocity = avg_velocity,
        sprint_count = #sprints
    }
end

return KanbanSprintQueries
