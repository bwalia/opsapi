--[[
    Kanban Time Tracking Queries
    ============================

    Production-ready time tracking system with:
    - Start/stop timers
    - Manual time entries
    - Billable hours calculation
    - Time reports and analytics
]]

local KanbanTimeEntryModel = require "models.KanbanTimeEntryModel"
local KanbanTaskModel = require "models.KanbanTaskModel"
local Global = require "helper.global"
local db = require("lapis.db")
local cjson = require("cjson.safe")

local KanbanTimeTrackingQueries = {}

--------------------------------------------------------------------------------
-- Timer Operations
--------------------------------------------------------------------------------

--- Start a timer for a task
-- @param task_id number Task ID
-- @param user_uuid string User UUID
-- @param description string|nil Optional description
-- @return table|nil Created entry or nil with error
function KanbanTimeTrackingQueries.startTimer(task_id, user_uuid, description)
    -- Check if user already has a running timer
    local running = db.query([[
        SELECT id, task_id FROM kanban_time_entries
        WHERE user_uuid = ? AND status = 'running' AND deleted_at IS NULL
        LIMIT 1
    ]], user_uuid)

    if running and #running > 0 then
        return nil, "You already have a running timer on another task. Stop it first."
    end

    -- Verify task exists
    local task = KanbanTaskModel:find({ id = task_id })
    if not task then
        return nil, "Task not found"
    end

    -- Get project hourly rate if available
    local project_info = db.query([[
        SELECT p.hourly_rate FROM kanban_projects p
        INNER JOIN kanban_boards b ON b.project_id = p.id
        WHERE b.id = ?
    ]], task.board_id)

    local hourly_rate = nil
    if project_info and #project_info > 0 then
        hourly_rate = project_info[1].hourly_rate
    end

    local entry = KanbanTimeEntryModel:create({
        uuid = Global.generateUUID(),
        task_id = task_id,
        user_uuid = user_uuid,
        description = description,
        started_at = db.raw("NOW()"),
        status = "running",
        is_billable = true,
        hourly_rate = hourly_rate,
        created_at = db.raw("NOW()"),
        updated_at = db.raw("NOW()")
    }, { returning = "*" })

    if entry then
        ngx.log(ngx.INFO, "[TimeTracking] Timer started: ", entry.uuid, " for task: ", task_id, " by user: ", user_uuid)
    end

    return entry
end

--- Stop a running timer
-- @param user_uuid string User UUID
-- @param description string|nil Optional updated description
-- @param accumulated_seconds number|nil Optional client-tracked seconds (more accurate)
-- @return table|nil Stopped entry or nil with error
function KanbanTimeTrackingQueries.stopTimer(user_uuid, description, accumulated_seconds)
    -- Find running timer
    local running = db.query([[
        SELECT * FROM kanban_time_entries
        WHERE user_uuid = ? AND status = 'running' AND deleted_at IS NULL
        ORDER BY started_at DESC
        LIMIT 1
    ]], user_uuid)

    if not running or #running == 0 then
        return nil, "No running timer found"
    end

    local entry = KanbanTimeEntryModel:find({ id = running[1].id })
    if not entry then
        return nil, "Timer entry not found"
    end

    -- Use client-provided seconds if available (more accurate), otherwise calculate from timestamps
    local duration_seconds
    local duration_minutes
    if accumulated_seconds and accumulated_seconds > 0 then
        duration_seconds = accumulated_seconds
        -- Round to nearest minute for display, minimum 1 minute if any time was tracked
        duration_minutes = math.floor((accumulated_seconds + 30) / 60)
        if duration_minutes == 0 and accumulated_seconds > 0 then
            duration_minutes = 1  -- At least 1 minute if any time was tracked
        end
    else
        -- Fallback: calculate from timestamps (less accurate due to network latency)
        local duration_result = db.query([[
            SELECT EXTRACT(EPOCH FROM (NOW() - ?::timestamp))::integer as seconds
        ]], entry.started_at)
        duration_seconds = duration_result[1].seconds or 0
        duration_minutes = math.floor((duration_seconds + 30) / 60)
        if duration_minutes == 0 and duration_seconds > 0 then
            duration_minutes = 1
        end
    end

    -- Calculate billed amount if billable
    local billed_amount = nil
    if entry.is_billable and entry.hourly_rate then
        billed_amount = (duration_minutes / 60.0) * tonumber(entry.hourly_rate)
    end

    local update_params = {
        ended_at = db.raw("NOW()"),
        duration_minutes = duration_minutes,
        duration_seconds = duration_seconds,  -- Store exact seconds for accurate resume
        status = "logged",
        billed_amount = billed_amount,
        updated_at = db.raw("NOW()")
    }

    if description then
        update_params.description = description
    end

    ngx.log(ngx.INFO, "[TimeTracking] Stopping timer - entry.id: ", entry.id, " task_id: ", entry.task_id, " duration_seconds: ", duration_seconds, " duration_minutes: ", duration_minutes)

    local success = entry:update(update_params)

    if not success then
        ngx.log(ngx.ERR, "[TimeTracking] Update failed for entry: ", entry.id)
        return nil, "Failed to stop timer"
    end

    ngx.log(ngx.INFO, "[TimeTracking] Timer stopped - entry updated to status=logged, duration_minutes=", duration_minutes)

    -- Refresh entry to get updated values
    entry:refresh()

    return entry
end

--- Get current running timer for user
-- @param user_uuid string User UUID
-- @return table|nil Running timer entry or nil
function KanbanTimeTrackingQueries.getRunningTimer(user_uuid)
    local sql = [[
        SELECT te.id,
               te.uuid,
               te.task_id,
               te.user_uuid,
               te.description,
               te.status,
               te.is_billable,
               te.hourly_rate,
               te.billed_amount,
               TO_CHAR(te.started_at AT TIME ZONE 'UTC', 'YYYY-MM-DD"T"HH24:MI:SS"Z"') as started_at,
               t.uuid as task_uuid,
               t.title as task_title,
               t.task_number,
               b.name as board_name,
               p.name as project_name,
               p.uuid as project_uuid,
               EXTRACT(EPOCH FROM (NOW() - te.started_at))::integer as elapsed_seconds,
               COALESCE((
                   SELECT SUM(COALESCE(prev.duration_seconds, prev.duration_minutes * 60))
                   FROM kanban_time_entries prev
                   WHERE prev.task_id = te.task_id
                     AND prev.user_uuid = te.user_uuid
                     AND prev.status != 'running'
                     AND prev.deleted_at IS NULL
               ), 0)::integer as previous_seconds
        FROM kanban_time_entries te
        INNER JOIN kanban_tasks t ON t.id = te.task_id
        INNER JOIN kanban_boards b ON b.id = t.board_id
        INNER JOIN kanban_projects p ON p.id = b.project_id
        WHERE te.user_uuid = ? AND te.status = 'running' AND te.deleted_at IS NULL
        LIMIT 1
    ]]

    local result = db.query(sql, user_uuid)
    if result and #result > 0 then
        return result[1]
    end
    return nil
end

--- Get total time spent on a task in seconds (for a specific user)
-- @param task_id number Task ID
-- @param user_uuid string User UUID
-- @return number Total seconds spent
function KanbanTimeTrackingQueries.getTaskTotalSeconds(task_id, user_uuid)
    -- Get sum of duration_seconds for all logged entries
    -- Use COALESCE to fall back to duration_minutes * 60 for legacy entries without duration_seconds
    local sql = [[
        SELECT COALESCE(
            SUM(COALESCE(duration_seconds, duration_minutes * 60)),
            0
        )::integer as total_seconds
        FROM kanban_time_entries
        WHERE task_id = ?
          AND user_uuid = ?
          AND status = 'logged'
          AND deleted_at IS NULL
    ]]

    local result = db.query(sql, task_id, user_uuid)
    local total_seconds = 0
    if result and #result > 0 then
        total_seconds = tonumber(result[1].total_seconds) or 0
    end

    ngx.log(ngx.INFO, "[TimeTracking] getTaskTotalSeconds - task_id: ", task_id, " user_uuid: ", user_uuid, " total_seconds: ", total_seconds)

    return total_seconds
end

--------------------------------------------------------------------------------
-- Manual Time Entry Operations
--------------------------------------------------------------------------------

--- Create a manual time entry
-- @param params table Entry parameters
-- @return table|nil Created entry or nil with error
function KanbanTimeTrackingQueries.create(params)
    if not params.uuid then
        params.uuid = Global.generateUUID()
    end

    -- Validate task exists
    local task = KanbanTaskModel:find({ id = params.task_id })
    if not task then
        return nil, "Task not found"
    end

    -- Calculate duration from start/end if not provided
    if not params.duration_minutes and params.started_at and params.ended_at then
        local duration_result = db.query([[
            SELECT EXTRACT(EPOCH FROM (?::timestamp - ?::timestamp))::integer / 60 as minutes
        ]], params.ended_at, params.started_at)
        params.duration_minutes = duration_result[1].minutes or 0
    end

    -- Get project hourly rate if not provided
    if not params.hourly_rate then
        local project_info = db.query([[
            SELECT p.hourly_rate FROM kanban_projects p
            INNER JOIN kanban_boards b ON b.project_id = p.id
            WHERE b.id = ?
        ]], task.board_id)

        if project_info and #project_info > 0 then
            params.hourly_rate = project_info[1].hourly_rate
        end
    end

    -- Calculate billed amount if billable
    if params.is_billable ~= false and params.hourly_rate and params.duration_minutes then
        params.billed_amount = (params.duration_minutes / 60.0) * tonumber(params.hourly_rate)
    end

    params.status = params.status or "logged"
    params.is_billable = params.is_billable ~= false
    params.created_at = db.raw("NOW()")
    params.updated_at = db.raw("NOW()")

    return KanbanTimeEntryModel:create(params, { returning = "*" })
end

--- Update a time entry
-- @param uuid string Entry UUID
-- @param params table Update parameters
-- @param user_uuid string User performing the update
-- @return table|nil Updated entry or nil with error
function KanbanTimeTrackingQueries.update(uuid, params, user_uuid)
    local entry = KanbanTimeEntryModel:find({ uuid = uuid })
    if not entry then
        return nil, "Time entry not found"
    end

    -- Only the user who created it or an admin can update
    if entry.user_uuid ~= user_uuid then
        return nil, "Permission denied"
    end

    -- Cannot edit approved or invoiced entries
    if entry.status == "approved" or entry.status == "invoiced" then
        return nil, "Cannot edit approved or invoiced time entries"
    end

    -- Recalculate duration if times changed
    local started_at = params.started_at or entry.started_at
    local ended_at = params.ended_at or entry.ended_at

    if params.started_at or params.ended_at then
        if ended_at then
            local duration_result = db.query([[
                SELECT EXTRACT(EPOCH FROM (?::timestamp - ?::timestamp))::integer / 60 as minutes
            ]], ended_at, started_at)
            params.duration_minutes = duration_result[1].minutes or entry.duration_minutes
        end
    end

    -- Recalculate billed amount if relevant fields changed
    local is_billable = params.is_billable ~= nil and params.is_billable or entry.is_billable
    local hourly_rate = params.hourly_rate or entry.hourly_rate
    local duration_minutes = params.duration_minutes or entry.duration_minutes

    if is_billable and hourly_rate and duration_minutes then
        params.billed_amount = (duration_minutes / 60.0) * tonumber(hourly_rate)
    elseif not is_billable then
        params.billed_amount = db.raw("NULL")
    end

    params.updated_at = db.raw("NOW()")

    local success = entry:update(params)
    if not success then
        return nil, "Failed to update time entry"
    end

    entry:refresh()
    return entry
end

--- Delete a time entry (soft delete)
-- @param uuid string Entry UUID
-- @param user_uuid string User performing the delete
-- @return boolean Success
function KanbanTimeTrackingQueries.delete(uuid, user_uuid)
    local entry = KanbanTimeEntryModel:find({ uuid = uuid })
    if not entry then
        return false, "Time entry not found"
    end

    -- Only the user who created it or an admin can delete
    if entry.user_uuid ~= user_uuid then
        return false, "Permission denied"
    end

    -- Cannot delete approved or invoiced entries
    if entry.status == "approved" or entry.status == "invoiced" then
        return false, "Cannot delete approved or invoiced time entries"
    end

    entry:update({
        deleted_at = db.raw("NOW()"),
        updated_at = db.raw("NOW()")
    })

    return true
end

--------------------------------------------------------------------------------
-- Approval Operations
--------------------------------------------------------------------------------

--- Approve a time entry
-- @param uuid string Entry UUID
-- @param approver_uuid string Approving user's UUID
-- @return table|nil Approved entry or nil with error
function KanbanTimeTrackingQueries.approve(uuid, approver_uuid)
    local entry = KanbanTimeEntryModel:find({ uuid = uuid })
    if not entry then
        return nil, "Time entry not found"
    end

    if entry.status ~= "logged" then
        return nil, "Only logged entries can be approved"
    end

    local success = entry:update({
        status = "approved",
        approved_by = approver_uuid,
        approved_at = db.raw("NOW()"),
        updated_at = db.raw("NOW()")
    })

    if not success then
        return nil, "Failed to approve time entry"
    end

    entry:refresh()
    return entry
end

--- Reject a time entry
-- @param uuid string Entry UUID
-- @param rejector_uuid string Rejecting user's UUID
-- @return table|nil Rejected entry or nil with error
function KanbanTimeTrackingQueries.reject(uuid, rejector_uuid)
    local entry = KanbanTimeEntryModel:find({ uuid = uuid })
    if not entry then
        return nil, "Time entry not found"
    end

    if entry.status ~= "logged" then
        return nil, "Only logged entries can be rejected"
    end

    local success = entry:update({
        status = "rejected",
        approved_by = rejector_uuid,
        approved_at = db.raw("NOW()"),
        updated_at = db.raw("NOW()")
    })

    if not success then
        return nil, "Failed to reject time entry"
    end

    entry:refresh()
    return entry
end

--------------------------------------------------------------------------------
-- Query Operations
--------------------------------------------------------------------------------

--- Get time entries for a task
-- @param task_id number Task ID
-- @param params table Pagination parameters
-- @return table { data, total }
function KanbanTimeTrackingQueries.getByTask(task_id, params)
    params = params or {}
    local page = params.page or 1
    local perPage = params.perPage or 20
    local offset = (page - 1) * perPage

    local sql = [[
        SELECT te.*, u.first_name, u.last_name, u.email
        FROM kanban_time_entries te
        INNER JOIN users u ON u.uuid = te.user_uuid
        WHERE te.task_id = ? AND te.deleted_at IS NULL
        ORDER BY te.started_at DESC
        LIMIT ? OFFSET ?
    ]]

    local entries = db.query(sql, task_id, perPage, offset)

    local count_sql = [[
        SELECT COUNT(*) as total FROM kanban_time_entries
        WHERE task_id = ? AND deleted_at IS NULL
    ]]
    local count_result = db.query(count_sql, task_id)
    local total = count_result and count_result[1] and count_result[1].total or 0

    return {
        data = entries,
        total = tonumber(total)
    }
end

--- Get time entries for a user (timesheet)
-- @param user_uuid string User UUID
-- @param params table Filter parameters
-- @return table { data, total, summary }
function KanbanTimeTrackingQueries.getByUser(user_uuid, params)
    params = params or {}
    local page = params.page or 1
    local perPage = params.perPage or 50
    local offset = (page - 1) * perPage

    local where_clauses = { "te.user_uuid = ?", "te.deleted_at IS NULL" }
    local where_values = { user_uuid }

    if params.start_date then
        table.insert(where_clauses, "te.started_at >= ?::date")
        table.insert(where_values, params.start_date)
    end

    if params.end_date then
        table.insert(where_clauses, "te.started_at < (?::date + INTERVAL '1 day')")
        table.insert(where_values, params.end_date)
    end

    if params.project_id then
        table.insert(where_clauses, "p.id = ?")
        table.insert(where_values, params.project_id)
    end

    if params.status then
        table.insert(where_clauses, "te.status = ?")
        table.insert(where_values, params.status)
    end

    local where_sql = table.concat(where_clauses, " AND ")

    local sql = string.format([[
        SELECT te.*,
               t.uuid as task_uuid,
               t.title as task_title,
               t.task_number,
               p.uuid as project_uuid,
               p.name as project_name
        FROM kanban_time_entries te
        INNER JOIN kanban_tasks t ON t.id = te.task_id
        INNER JOIN kanban_boards b ON b.id = t.board_id
        INNER JOIN kanban_projects p ON p.id = b.project_id
        WHERE %s
        ORDER BY te.started_at DESC
        LIMIT ? OFFSET ?
    ]], where_sql)

    table.insert(where_values, perPage)
    table.insert(where_values, offset)

    local entries = db.query(sql, table.unpack(where_values))

    -- Count query
    local count_values = {}
    for i = 1, #where_values - 2 do
        table.insert(count_values, where_values[i])
    end

    local count_sql = string.format([[
        SELECT COUNT(*) as total
        FROM kanban_time_entries te
        INNER JOIN kanban_tasks t ON t.id = te.task_id
        INNER JOIN kanban_boards b ON b.id = t.board_id
        INNER JOIN kanban_projects p ON p.id = b.project_id
        WHERE %s
    ]], where_sql)

    local count_result = db.query(count_sql, table.unpack(count_values))
    local total = count_result and count_result[1] and count_result[1].total or 0

    -- Summary query
    local summary_sql = string.format([[
        SELECT
            SUM(te.duration_minutes) as total_minutes,
            SUM(CASE WHEN te.is_billable THEN te.duration_minutes ELSE 0 END) as billable_minutes,
            SUM(COALESCE(te.billed_amount, 0)) as total_billed
        FROM kanban_time_entries te
        INNER JOIN kanban_tasks t ON t.id = te.task_id
        INNER JOIN kanban_boards b ON b.id = t.board_id
        INNER JOIN kanban_projects p ON p.id = b.project_id
        WHERE %s
    ]], where_sql)

    local summary_result = db.query(summary_sql, table.unpack(count_values))
    local summary = {
        total_minutes = tonumber(summary_result[1].total_minutes) or 0,
        billable_minutes = tonumber(summary_result[1].billable_minutes) or 0,
        total_billed = tonumber(summary_result[1].total_billed) or 0
    }

    return {
        data = entries,
        total = tonumber(total),
        summary = summary
    }
end

--- Get time entries for a project
-- @param project_id number Project ID
-- @param params table Filter parameters
-- @return table { data, total, summary }
function KanbanTimeTrackingQueries.getByProject(project_id, params)
    params = params or {}
    local page = params.page or 1
    local perPage = params.perPage or 50
    local offset = (page - 1) * perPage

    local where_clauses = { "p.id = ?", "te.deleted_at IS NULL" }
    local where_values = { project_id }

    if params.start_date then
        table.insert(where_clauses, "te.started_at >= ?::date")
        table.insert(where_values, params.start_date)
    end

    if params.end_date then
        table.insert(where_clauses, "te.started_at < (?::date + INTERVAL '1 day')")
        table.insert(where_values, params.end_date)
    end

    if params.user_uuid then
        table.insert(where_clauses, "te.user_uuid = ?")
        table.insert(where_values, params.user_uuid)
    end

    if params.status then
        table.insert(where_clauses, "te.status = ?")
        table.insert(where_values, params.status)
    end

    local where_sql = table.concat(where_clauses, " AND ")

    local sql = string.format([[
        SELECT te.*,
               t.uuid as task_uuid,
               t.title as task_title,
               t.task_number,
               u.first_name,
               u.last_name,
               u.email
        FROM kanban_time_entries te
        INNER JOIN kanban_tasks t ON t.id = te.task_id
        INNER JOIN kanban_boards b ON b.id = t.board_id
        INNER JOIN kanban_projects p ON p.id = b.project_id
        INNER JOIN users u ON u.uuid = te.user_uuid
        WHERE %s
        ORDER BY te.started_at DESC
        LIMIT ? OFFSET ?
    ]], where_sql)

    table.insert(where_values, perPage)
    table.insert(where_values, offset)

    local entries = db.query(sql, table.unpack(where_values))

    -- Count and summary queries (similar pattern)
    local count_values = {}
    for i = 1, #where_values - 2 do
        table.insert(count_values, where_values[i])
    end

    local count_sql = string.format([[
        SELECT COUNT(*) as total
        FROM kanban_time_entries te
        INNER JOIN kanban_tasks t ON t.id = te.task_id
        INNER JOIN kanban_boards b ON b.id = t.board_id
        INNER JOIN kanban_projects p ON p.id = b.project_id
        WHERE %s
    ]], where_sql)

    local count_result = db.query(count_sql, table.unpack(count_values))
    local total = count_result and count_result[1] and count_result[1].total or 0

    local summary_sql = string.format([[
        SELECT
            SUM(te.duration_minutes) as total_minutes,
            SUM(CASE WHEN te.is_billable THEN te.duration_minutes ELSE 0 END) as billable_minutes,
            SUM(COALESCE(te.billed_amount, 0)) as total_billed,
            COUNT(DISTINCT te.user_uuid) as unique_users
        FROM kanban_time_entries te
        INNER JOIN kanban_tasks t ON t.id = te.task_id
        INNER JOIN kanban_boards b ON b.id = t.board_id
        INNER JOIN kanban_projects p ON p.id = b.project_id
        WHERE %s
    ]], where_sql)

    local summary_result = db.query(summary_sql, table.unpack(count_values))
    local summary = {
        total_minutes = tonumber(summary_result[1].total_minutes) or 0,
        billable_minutes = tonumber(summary_result[1].billable_minutes) or 0,
        total_billed = tonumber(summary_result[1].total_billed) or 0,
        unique_users = tonumber(summary_result[1].unique_users) or 0
    }

    return {
        data = entries,
        total = tonumber(total),
        summary = summary
    }
end

--- Get time report by user for a date range
-- @param project_id number Project ID
-- @param start_date string Start date
-- @param end_date string End date
-- @return table[] User time summaries
function KanbanTimeTrackingQueries.getUserReport(project_id, start_date, end_date)
    local sql = [[
        SELECT
            te.user_uuid,
            u.first_name,
            u.last_name,
            u.email,
            SUM(te.duration_minutes) as total_minutes,
            SUM(CASE WHEN te.is_billable THEN te.duration_minutes ELSE 0 END) as billable_minutes,
            SUM(COALESCE(te.billed_amount, 0)) as total_billed,
            COUNT(*) as entry_count
        FROM kanban_time_entries te
        INNER JOIN kanban_tasks t ON t.id = te.task_id
        INNER JOIN kanban_boards b ON b.id = t.board_id
        INNER JOIN kanban_projects p ON p.id = b.project_id
        INNER JOIN users u ON u.uuid = te.user_uuid
        WHERE p.id = ?
          AND te.deleted_at IS NULL
          AND te.started_at >= ?::date
          AND te.started_at < (?::date + INTERVAL '1 day')
        GROUP BY te.user_uuid, u.first_name, u.last_name, u.email
        ORDER BY total_minutes DESC
    ]]

    return db.query(sql, project_id, start_date, end_date)
end

return KanbanTimeTrackingQueries
