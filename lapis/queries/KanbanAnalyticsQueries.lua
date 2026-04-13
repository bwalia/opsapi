--[[
    Kanban Analytics Queries
    ========================

    Production-ready analytics for project management:
    - Project progress metrics
    - Team performance insights
    - Task completion trends
    - Cycle time analysis
    - Activity streams
]]

local db = require("lapis.db")
local cjson = require("cjson.safe")

local KanbanAnalyticsQueries = {}

--------------------------------------------------------------------------------
-- Project Analytics
--------------------------------------------------------------------------------

--- Get comprehensive project statistics
-- @param project_id number Project ID
-- @return table Project stats
function KanbanAnalyticsQueries.getProjectStats(project_id)
    -- Task counts by status
    local task_stats = db.query([[
        SELECT
            COUNT(*) as total_tasks,
            SUM(CASE WHEN t.status = 'open' THEN 1 ELSE 0 END) as open_tasks,
            SUM(CASE WHEN t.status = 'in_progress' THEN 1 ELSE 0 END) as in_progress_tasks,
            SUM(CASE WHEN t.status = 'blocked' THEN 1 ELSE 0 END) as blocked_tasks,
            SUM(CASE WHEN t.status = 'review' THEN 1 ELSE 0 END) as review_tasks,
            SUM(CASE WHEN t.status = 'completed' THEN 1 ELSE 0 END) as completed_tasks,
            SUM(CASE WHEN t.status = 'cancelled' THEN 1 ELSE 0 END) as cancelled_tasks,
            SUM(CASE WHEN t.due_date < CURRENT_DATE AND t.status NOT IN ('completed', 'cancelled') THEN 1 ELSE 0 END) as overdue_tasks,
            SUM(CASE WHEN t.due_date = CURRENT_DATE AND t.status NOT IN ('completed', 'cancelled') THEN 1 ELSE 0 END) as due_today_tasks,
            SUM(COALESCE(t.story_points, 0)) as total_points,
            SUM(CASE WHEN t.status = 'completed' THEN COALESCE(t.story_points, 0) ELSE 0 END) as completed_points
        FROM kanban_tasks t
        INNER JOIN kanban_boards b ON b.id = t.board_id
        WHERE b.project_id = ? AND t.deleted_at IS NULL AND t.archived_at IS NULL
    ]], project_id)

    -- Member stats
    local member_stats = db.query([[
        SELECT COUNT(*) as member_count
        FROM kanban_project_members
        WHERE project_id = ? AND left_at IS NULL AND deleted_at IS NULL
    ]], project_id)

    -- Board count
    local board_stats = db.query([[
        SELECT COUNT(*) as board_count
        FROM kanban_boards
        WHERE project_id = ? AND deleted_at IS NULL AND archived_at IS NULL
    ]], project_id)

    -- Sprint stats
    local sprint_stats = db.query([[
        SELECT
            COUNT(*) as total_sprints,
            SUM(CASE WHEN status = 'active' THEN 1 ELSE 0 END) as active_sprints,
            SUM(CASE WHEN status = 'completed' THEN 1 ELSE 0 END) as completed_sprints,
            AVG(CASE WHEN status = 'completed' THEN velocity ELSE NULL END) as avg_velocity
        FROM kanban_sprints
        WHERE project_id = ? AND deleted_at IS NULL
    ]], project_id)

    -- Time tracking stats
    local time_stats = db.query([[
        SELECT
            SUM(te.duration_minutes) as total_minutes,
            SUM(CASE WHEN te.is_billable THEN te.duration_minutes ELSE 0 END) as billable_minutes,
            SUM(COALESCE(te.billed_amount, 0)) as total_billed
        FROM kanban_time_entries te
        INNER JOIN kanban_tasks t ON t.id = te.task_id
        INNER JOIN kanban_boards b ON b.id = t.board_id
        WHERE b.project_id = ? AND te.deleted_at IS NULL
    ]], project_id)

    -- Budget info
    local budget_stats = db.query([[
        SELECT budget, budget_spent, budget_currency
        FROM kanban_projects
        WHERE id = ?
    ]], project_id)

    local stats = {
        tasks = task_stats and task_stats[1] or {},
        members = member_stats and member_stats[1] or {},
        boards = board_stats and board_stats[1] or {},
        sprints = sprint_stats and sprint_stats[1] or {},
        time = time_stats and time_stats[1] or {},
        budget = budget_stats and budget_stats[1] or {}
    }

    -- Calculate progress percentage
    local total = tonumber(stats.tasks.total_tasks) or 0
    local completed = tonumber(stats.tasks.completed_tasks) or 0
    stats.progress_percentage = total > 0 and math.floor((completed / total) * 100) or 0

    return stats
end

--- Get task completion trend over time
-- @param project_id number Project ID
-- @param days number Number of days to look back (default 30)
-- @return table[] Daily completion data
function KanbanAnalyticsQueries.getCompletionTrend(project_id, days)
    days = days or 30

    local sql = [[
        WITH date_series AS (
            SELECT generate_series(
                CURRENT_DATE - ?::integer,
                CURRENT_DATE,
                '1 day'::interval
            )::date as date
        ),
        daily_completed AS (
            SELECT
                DATE(t.completed_at) as date,
                COUNT(*) as completed_count,
                SUM(COALESCE(t.story_points, 0)) as completed_points
            FROM kanban_tasks t
            INNER JOIN kanban_boards b ON b.id = t.board_id
            WHERE b.project_id = ?
              AND t.status = 'completed'
              AND t.completed_at >= CURRENT_DATE - ?::integer
              AND t.deleted_at IS NULL
            GROUP BY DATE(t.completed_at)
        ),
        daily_created AS (
            SELECT
                DATE(t.created_at) as date,
                COUNT(*) as created_count
            FROM kanban_tasks t
            INNER JOIN kanban_boards b ON b.id = t.board_id
            WHERE b.project_id = ?
              AND t.created_at >= CURRENT_DATE - ?::integer
              AND t.deleted_at IS NULL
            GROUP BY DATE(t.created_at)
        )
        SELECT
            ds.date,
            COALESCE(dc.completed_count, 0) as completed_count,
            COALESCE(dc.completed_points, 0) as completed_points,
            COALESCE(dcr.created_count, 0) as created_count
        FROM date_series ds
        LEFT JOIN daily_completed dc ON dc.date = ds.date
        LEFT JOIN daily_created dcr ON dcr.date = ds.date
        ORDER BY ds.date ASC
    ]]

    return db.query(sql, days, project_id, days, project_id, days)
end

--- Get tasks by priority distribution
-- @param project_id number Project ID
-- @return table[] Priority distribution
function KanbanAnalyticsQueries.getPriorityDistribution(project_id)
    local sql = [[
        SELECT
            t.priority,
            COUNT(*) as count,
            SUM(CASE WHEN t.status NOT IN ('completed', 'cancelled') THEN 1 ELSE 0 END) as active_count
        FROM kanban_tasks t
        INNER JOIN kanban_boards b ON b.id = t.board_id
        WHERE b.project_id = ? AND t.deleted_at IS NULL AND t.archived_at IS NULL
        GROUP BY t.priority
        ORDER BY
            CASE t.priority
                WHEN 'critical' THEN 1
                WHEN 'high' THEN 2
                WHEN 'medium' THEN 3
                WHEN 'low' THEN 4
                ELSE 5
            END
    ]]

    return db.query(sql, project_id)
end

--------------------------------------------------------------------------------
-- Team Analytics
--------------------------------------------------------------------------------

--- Get team member workload distribution
-- @param project_id number Project ID
-- @return table[] Member workload data
function KanbanAnalyticsQueries.getTeamWorkload(project_id)
    local sql = [[
        SELECT
            u.uuid as user_uuid,
            u.first_name,
            u.last_name,
            u.email,
            pm.role,
            COUNT(DISTINCT ta.task_id) as assigned_tasks,
            SUM(CASE WHEN t.status NOT IN ('completed', 'cancelled') THEN 1 ELSE 0 END) as active_tasks,
            SUM(CASE WHEN t.status = 'completed' THEN 1 ELSE 0 END) as completed_tasks,
            SUM(CASE WHEN t.status = 'in_progress' THEN 1 ELSE 0 END) as in_progress_tasks,
            SUM(CASE WHEN t.due_date < CURRENT_DATE AND t.status NOT IN ('completed', 'cancelled') THEN 1 ELSE 0 END) as overdue_tasks,
            SUM(COALESCE(t.story_points, 0)) as total_points,
            SUM(CASE WHEN t.status = 'completed' THEN COALESCE(t.story_points, 0) ELSE 0 END) as completed_points
        FROM kanban_project_members pm
        INNER JOIN users u ON u.uuid = pm.user_uuid
        LEFT JOIN kanban_task_assignees ta ON ta.user_uuid = pm.user_uuid AND ta.deleted_at IS NULL
        LEFT JOIN kanban_tasks t ON t.id = ta.task_id AND t.deleted_at IS NULL AND t.archived_at IS NULL
        LEFT JOIN kanban_boards b ON b.id = t.board_id AND b.project_id = ?
        WHERE pm.project_id = ? AND pm.left_at IS NULL AND pm.deleted_at IS NULL
        GROUP BY u.uuid, u.first_name, u.last_name, u.email, pm.role
        ORDER BY active_tasks DESC
    ]]

    return db.query(sql, project_id, project_id)
end

--- Get team member activity over time
-- @param project_id number Project ID
-- @param user_uuid string User UUID
-- @param days number Number of days
-- @return table[] Daily activity data
function KanbanAnalyticsQueries.getMemberActivity(project_id, user_uuid, days)
    days = days or 30

    local sql = [[
        WITH date_series AS (
            SELECT generate_series(
                CURRENT_DATE - ?::integer,
                CURRENT_DATE,
                '1 day'::interval
            )::date as date
        ),
        daily_activity AS (
            SELECT
                DATE(a.created_at) as date,
                COUNT(*) as activity_count,
                SUM(CASE WHEN a.action = 'completed' THEN 1 ELSE 0 END) as completed_count,
                SUM(CASE WHEN a.action = 'commented' THEN 1 ELSE 0 END) as comment_count
            FROM kanban_task_activities a
            INNER JOIN kanban_tasks t ON t.id = a.task_id
            INNER JOIN kanban_boards b ON b.id = t.board_id
            WHERE b.project_id = ?
              AND a.user_uuid = ?
              AND a.created_at >= CURRENT_DATE - ?::integer
            GROUP BY DATE(a.created_at)
        ),
        daily_time AS (
            SELECT
                DATE(te.started_at) as date,
                SUM(te.duration_minutes) as time_spent
            FROM kanban_time_entries te
            INNER JOIN kanban_tasks t ON t.id = te.task_id
            INNER JOIN kanban_boards b ON b.id = t.board_id
            WHERE b.project_id = ?
              AND te.user_uuid = ?
              AND te.started_at >= CURRENT_DATE - ?::integer
              AND te.deleted_at IS NULL
            GROUP BY DATE(te.started_at)
        )
        SELECT
            ds.date,
            COALESCE(da.activity_count, 0) as activity_count,
            COALESCE(da.completed_count, 0) as completed_count,
            COALESCE(da.comment_count, 0) as comment_count,
            COALESCE(dt.time_spent, 0) as time_spent_minutes
        FROM date_series ds
        LEFT JOIN daily_activity da ON da.date = ds.date
        LEFT JOIN daily_time dt ON dt.date = ds.date
        ORDER BY ds.date ASC
    ]]

    return db.query(sql, days, project_id, user_uuid, days, project_id, user_uuid, days)
end

--------------------------------------------------------------------------------
-- Cycle Time Analytics
--------------------------------------------------------------------------------

--- Get average cycle time by column
-- @param project_id number Project ID
-- @return table[] Cycle time by column
function KanbanAnalyticsQueries.getCycleTimeByColumn(project_id)
    -- This requires tracking when tasks enter/exit columns
    -- For now, calculate based on completed tasks
    local sql = [[
        SELECT
            c.name as column_name,
            c.color as column_color,
            c.position,
            AVG(
                EXTRACT(EPOCH FROM (t.completed_at - t.created_at)) / 3600
            ) as avg_hours_to_complete,
            COUNT(*) as task_count
        FROM kanban_tasks t
        INNER JOIN kanban_columns c ON c.id = t.column_id
        INNER JOIN kanban_boards b ON b.id = t.board_id
        WHERE b.project_id = ?
          AND t.status = 'completed'
          AND t.completed_at IS NOT NULL
          AND t.deleted_at IS NULL
        GROUP BY c.id, c.name, c.color, c.position
        ORDER BY c.position
    ]]

    return db.query(sql, project_id)
end

--- Get average time to complete by priority
-- @param project_id number Project ID
-- @return table[] Cycle time by priority
function KanbanAnalyticsQueries.getCycleTimeByPriority(project_id)
    local sql = [[
        SELECT
            t.priority,
            AVG(
                EXTRACT(EPOCH FROM (t.completed_at - t.created_at)) / 3600
            ) as avg_hours,
            MIN(
                EXTRACT(EPOCH FROM (t.completed_at - t.created_at)) / 3600
            ) as min_hours,
            MAX(
                EXTRACT(EPOCH FROM (t.completed_at - t.created_at)) / 3600
            ) as max_hours,
            COUNT(*) as task_count
        FROM kanban_tasks t
        INNER JOIN kanban_boards b ON b.id = t.board_id
        WHERE b.project_id = ?
          AND t.status = 'completed'
          AND t.completed_at IS NOT NULL
          AND t.deleted_at IS NULL
        GROUP BY t.priority
        ORDER BY
            CASE t.priority
                WHEN 'critical' THEN 1
                WHEN 'high' THEN 2
                WHEN 'medium' THEN 3
                WHEN 'low' THEN 4
                ELSE 5
            END
    ]]

    return db.query(sql, project_id)
end

--------------------------------------------------------------------------------
-- Activity Feed
--------------------------------------------------------------------------------

--- Get project activity feed
-- @param project_id number Project ID
-- @param params table Filter parameters
-- @return table { data, total }
function KanbanAnalyticsQueries.getProjectActivityFeed(project_id, params)
    params = params or {}
    local page = params.page or 1
    local perPage = params.perPage or 50
    local offset = (page - 1) * perPage

    local where_clauses = { "p.id = ?" }
    local where_values = { project_id }

    if params.user_uuid then
        table.insert(where_clauses, "a.user_uuid = ?")
        table.insert(where_values, params.user_uuid)
    end

    if params.action then
        table.insert(where_clauses, "a.action = ?")
        table.insert(where_values, params.action)
    end

    if params.since then
        table.insert(where_clauses, "a.created_at >= ?::timestamp")
        table.insert(where_values, params.since)
    end

    local where_sql = table.concat(where_clauses, " AND ")

    local sql = string.format([[
        SELECT
            a.id,
            a.uuid,
            a.task_id,
            a.user_uuid,
            a.action,
            a.entity_type,
            a.entity_id,
            a.old_value,
            a.new_value,
            a.metadata,
            a.created_at,
            t.uuid as task_uuid,
            t.title as task_title,
            t.task_number,
            b.uuid as board_uuid,
            b.name as board_name,
            u.first_name,
            u.last_name,
            u.email
        FROM kanban_task_activities a
        INNER JOIN kanban_tasks t ON t.id = a.task_id
        INNER JOIN kanban_boards b ON b.id = t.board_id
        INNER JOIN kanban_projects p ON p.id = b.project_id
        LEFT JOIN users u ON u.uuid = a.user_uuid
        WHERE %s
        ORDER BY a.created_at DESC
        LIMIT ? OFFSET ?
    ]], where_sql)

    table.insert(where_values, perPage)
    table.insert(where_values, offset)

    local activities = db.query(sql, table.unpack(where_values))

    -- Count query
    local count_sql = string.format([[
        SELECT COUNT(*) as total
        FROM kanban_task_activities a
        INNER JOIN kanban_tasks t ON t.id = a.task_id
        INNER JOIN kanban_boards b ON b.id = t.board_id
        INNER JOIN kanban_projects p ON p.id = b.project_id
        WHERE %s
    ]], where_sql)

    local count_values = {}
    for i = 1, #where_values - 2 do
        table.insert(count_values, where_values[i])
    end

    local count_result = db.query(count_sql, table.unpack(count_values))
    local total = count_result and count_result[1] and count_result[1].total or 0

    return {
        data = activities,
        total = tonumber(total)
    }
end

--- Get recent activity summary
-- @param project_id number Project ID
-- @param hours number Hours to look back (default 24)
-- @return table Activity summary
function KanbanAnalyticsQueries.getRecentActivitySummary(project_id, hours)
    hours = hours or 24

    local sql = [[
        SELECT
            a.action,
            COUNT(*) as count
        FROM kanban_task_activities a
        INNER JOIN kanban_tasks t ON t.id = a.task_id
        INNER JOIN kanban_boards b ON b.id = t.board_id
        WHERE b.project_id = ?
          AND a.created_at >= NOW() - (?::integer || ' hours')::interval
        GROUP BY a.action
        ORDER BY count DESC
    ]]

    local by_action = db.query(sql, project_id, hours)

    -- Most active users
    local active_users = db.query([[
        SELECT
            a.user_uuid,
            u.first_name,
            u.last_name,
            COUNT(*) as activity_count
        FROM kanban_task_activities a
        INNER JOIN kanban_tasks t ON t.id = a.task_id
        INNER JOIN kanban_boards b ON b.id = t.board_id
        LEFT JOIN users u ON u.uuid = a.user_uuid
        WHERE b.project_id = ?
          AND a.created_at >= NOW() - (?::integer || ' hours')::interval
        GROUP BY a.user_uuid, u.first_name, u.last_name
        ORDER BY activity_count DESC
        LIMIT 5
    ]], project_id, hours)

    -- Total count
    local total = db.query([[
        SELECT COUNT(*) as count
        FROM kanban_task_activities a
        INNER JOIN kanban_tasks t ON t.id = a.task_id
        INNER JOIN kanban_boards b ON b.id = t.board_id
        WHERE b.project_id = ?
          AND a.created_at >= NOW() - (?::integer || ' hours')::interval
    ]], project_id, hours)

    return {
        by_action = by_action,
        active_users = active_users,
        total_activities = total and total[1] and tonumber(total[1].count) or 0,
        hours = hours
    }
end

--------------------------------------------------------------------------------
-- Label Analytics
--------------------------------------------------------------------------------

--- Get label usage statistics
-- @param project_id number Project ID
-- @return table[] Label usage data
function KanbanAnalyticsQueries.getLabelStats(project_id)
    local sql = [[
        SELECT
            l.uuid,
            l.name,
            l.color,
            l.usage_count,
            COUNT(DISTINCT ll.task_id) as active_task_count,
            SUM(CASE WHEN t.status NOT IN ('completed', 'cancelled') THEN 1 ELSE 0 END) as open_task_count
        FROM kanban_task_labels l
        LEFT JOIN kanban_task_label_links ll ON ll.label_id = l.id AND ll.deleted_at IS NULL
        LEFT JOIN kanban_tasks t ON t.id = ll.task_id AND t.deleted_at IS NULL AND t.archived_at IS NULL
        WHERE l.project_id = ? AND l.deleted_at IS NULL
        GROUP BY l.id, l.uuid, l.name, l.color, l.usage_count
        ORDER BY usage_count DESC
    ]]

    return db.query(sql, project_id)
end

return KanbanAnalyticsQueries
