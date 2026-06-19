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
-- Billing bridge
--------------------------------------------------------------------------------

--- Mirror a finalized kanban time entry into the Timesheets billing pipeline:
--- one DRAFT timesheet per user per day per the task's customer. Best-effort and
--- fully isolated — any failure (timesheets/customers tables absent on a
--- kanban-only deployment, etc.) is swallowed so board time tracking never breaks.
-- @param entry table A logged kanban_time_entries row (needs task_id, user_uuid,
--                    duration_minutes, is_billable, hourly_rate, description)
local function mirror_to_timesheet(entry)
    if not entry or not entry.task_id then return end
    local minutes = tonumber(entry.duration_minutes)
    if not minutes or minutes <= 0 then return end

    local ok, err = pcall(function()
        local TimesheetQueries = require "queries.TimesheetQueries"
        local ctx = db.query([[
            SELECT t.uuid AS task_uuid, t.title AS task_title,
                   p.namespace_id, p.uuid AS project_uuid, p.name AS project_name,
                   p.customer_uuid,
                   NULLIF(TRIM(CONCAT(c.first_name, ' ', c.last_name)), '') AS customer_name
            FROM kanban_tasks t
            JOIN kanban_boards b ON b.id = t.board_id
            JOIN kanban_projects p ON p.id = b.project_id
            LEFT JOIN customers c ON c.uuid = p.customer_uuid AND c.namespace_id = p.namespace_id
            WHERE t.id = ?
            LIMIT 1
        ]], entry.task_id)
        if not ctx or not ctx[1] then
            ngx.log(ngx.WARN, "[TimeBridge] no task context for task_id=", entry.task_id)
            return
        end
        local row = ctx[1]

        local res, append_err = TimesheetQueries.appendDailyEntry({
            namespace_id  = row.namespace_id,
            user_uuid     = entry.user_uuid,
            hours         = minutes / 60.0,
            customer_uuid = row.customer_uuid,
            customer_name = row.customer_name,
            task_uuid     = row.task_uuid,
            task_title    = row.task_title,
            project_uuid  = row.project_uuid,
            project_name  = row.project_name,
            is_billable   = entry.is_billable,
            hourly_rate   = entry.hourly_rate,
            description   = entry.description,
        })
        if not res then
            ngx.log(ngx.WARN, "[TimeBridge] appendDailyEntry failed: ", tostring(append_err))
        else
            ngx.log(ngx.INFO, "[TimeBridge] created timesheet=", res.timesheet_uuid, " entry=", res.entry_uuid)
        end
    end)
    if not ok then
        ngx.log(ngx.ERR, "[TimeBridge] mirror error: ", tostring(err))
    end
end

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
        duration_seconds = (duration_result and duration_result[1] and duration_result[1].seconds) or 0
        if duration_seconds < 0 then duration_seconds = 0 end
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

    -- Mirror this finalized session into the Timesheets billing pipeline.
    mirror_to_timesheet(entry)

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

    local created = KanbanTimeEntryModel:create(params, { returning = "*" })

    -- Mirror this manual entry into the Timesheets billing pipeline.
    mirror_to_timesheet(created)

    return created
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
    local s = (summary_result and summary_result[1]) or {}
    local summary = {
        total_minutes = tonumber(s.total_minutes) or 0,
        billable_minutes = tonumber(s.billable_minutes) or 0,
        total_billed = tonumber(s.total_billed) or 0
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
    local s = (summary_result and summary_result[1]) or {}
    local summary = {
        total_minutes = tonumber(s.total_minutes) or 0,
        billable_minutes = tonumber(s.billable_minutes) or 0,
        total_billed = tonumber(s.total_billed) or 0,
        unique_users = tonumber(s.unique_users) or 0
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

--------------------------------------------------------------------------------
-- Combined per-task time summary
--------------------------------------------------------------------------------

--- Total time spent on a task across BOTH tracking surfaces, per contributor:
---   * kanban_time_entries   — logged via the board timer / manual entry
---   * timesheet_entries     — logged via the Timesheets module (source != 'kanban')
--- The forward bridge mirrors kanban entries into timesheet_entries tagged
--- source='kanban'; those are excluded here so the same minutes are never counted
--- twice. The timesheet half is wrapped in pcall so kanban-only deployments
--- (no timesheet_entries table) still return the kanban totals.
-- @param task_id   number  internal kanban_tasks.id
-- @param task_uuid string  kanban_tasks.uuid (how timesheet entries reference it)
-- @return table { total_minutes, kanban_minutes, timesheet_minutes,
--                 billable_minutes, by_user = { { user_uuid, name, email,
--                 kanban_minutes, timesheet_minutes, total_minutes } } }
function KanbanTimeTrackingQueries.getTaskTimeSummary(task_id, task_uuid)
    -- Kanban board time, grouped by contributor.
    local kanban_rows = db.query([[
        SELECT te.user_uuid,
               COALESCE(u.first_name, '') AS first_name,
               COALESCE(u.last_name, '')  AS last_name,
               u.email,
               COALESCE(SUM(te.duration_minutes), 0)::int AS minutes,
               COALESCE(SUM(CASE WHEN te.is_billable
                                 THEN te.duration_minutes ELSE 0 END), 0)::int AS billable_minutes
        FROM kanban_time_entries te
        LEFT JOIN users u ON u.uuid = te.user_uuid
        WHERE te.task_id = ? AND te.deleted_at IS NULL
        GROUP BY te.user_uuid, u.first_name, u.last_name, u.email
    ]], task_id) or {}

    -- Timesheet time attributed to this task, excluding kanban mirrors.
    local ts_rows = {}
    if task_uuid then
        local ok, rows = pcall(function()
            return db.query([[
                SELECT e.user_uuid,
                       COALESCE(u.first_name, '') AS first_name,
                       COALESCE(u.last_name, '')  AS last_name,
                       u.email,
                       COALESCE(SUM(e.hours) * 60, 0)::int AS minutes,
                       COALESCE(SUM(CASE WHEN e.is_billable
                                         THEN e.hours ELSE 0 END) * 60, 0)::int AS billable_minutes
                FROM timesheet_entries e
                LEFT JOIN users u ON u.uuid = e.user_uuid
                WHERE e.task_uuid = ?
                  AND e.deleted_at IS NULL
                  AND COALESCE(e.source, 'manual') <> 'kanban'
                GROUP BY e.user_uuid, u.first_name, u.last_name, u.email
            ]], task_uuid)
        end)
        if ok and rows then ts_rows = rows end
    end

    -- Merge the two sources per user.
    local by_user = {}
    local function bucket(r)
        local b = by_user[r.user_uuid]
        if not b then
            local name = (tostring(r.first_name or "") .. " " .. tostring(r.last_name or "")):gsub("^%s*(.-)%s*$", "%1")
            b = {
                user_uuid = r.user_uuid,
                name = (name ~= "" and name) or r.email or "Unknown",
                email = r.email,
                kanban_minutes = 0,
                timesheet_minutes = 0,
                total_minutes = 0,
                billable_minutes = 0,
            }
            by_user[r.user_uuid] = b
        end
        return b
    end

    local total, kanban_total, ts_total, billable_total = 0, 0, 0, 0
    for _, r in ipairs(kanban_rows) do
        local b = bucket(r)
        b.kanban_minutes = b.kanban_minutes + (r.minutes or 0)
        b.total_minutes = b.total_minutes + (r.minutes or 0)
        b.billable_minutes = b.billable_minutes + (r.billable_minutes or 0)
        kanban_total = kanban_total + (r.minutes or 0)
        total = total + (r.minutes or 0)
        billable_total = billable_total + (r.billable_minutes or 0)
    end
    for _, r in ipairs(ts_rows) do
        local b = bucket(r)
        b.timesheet_minutes = b.timesheet_minutes + (r.minutes or 0)
        b.total_minutes = b.total_minutes + (r.minutes or 0)
        b.billable_minutes = b.billable_minutes + (r.billable_minutes or 0)
        ts_total = ts_total + (r.minutes or 0)
        total = total + (r.minutes or 0)
        billable_total = billable_total + (r.billable_minutes or 0)
    end

    -- Stable array ordered by most time first.
    local users = {}
    for _, b in pairs(by_user) do users[#users + 1] = b end
    table.sort(users, function(a, c) return a.total_minutes > c.total_minutes end)

    return {
        total_minutes = total,
        kanban_minutes = kanban_total,
        timesheet_minutes = ts_total,
        billable_minutes = billable_total,
        by_user = users,
    }
end

return KanbanTimeTrackingQueries
