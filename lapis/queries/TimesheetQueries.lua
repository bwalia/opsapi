local TimesheetModel = require("models.TimesheetModel")
local TimesheetEntryModel = require("models.TimesheetEntryModel")
local TimesheetApprovalModel = require("models.TimesheetApprovalModel")
local Global = require("helper.global")
local db = require("lapis.db")

local TimesheetQueries = {}

-- ============================================================
-- INTERNAL HELPERS
-- ============================================================

local function _recalculate_totals(timesheet_id)
    local result = db.query([[
        SELECT
            COALESCE(SUM(hours), 0) as total_hours,
            COALESCE(SUM(CASE WHEN is_billable = true THEN hours ELSE 0 END), 0) as billable_hours
        FROM timesheet_entries
        WHERE timesheet_id = ? AND deleted_at IS NULL
    ]], timesheet_id)

    if result and result[1] then
        db.query([[
            UPDATE timesheets
            SET total_hours = ?, billable_hours = ?, updated_at = NOW()
            WHERE id = ?
        ]], result[1].total_hours, result[1].billable_hours, timesheet_id)
    end
end

-- ============================================================
-- TIMESHEET CRUD
-- ============================================================

-- Parse a "HH:MM" (or "HH:MM:SS") clock string into minutes-since-midnight.
local function time_to_minutes(t)
    if not t or t == "" then return nil end
    local h, m = tostring(t):match("^(%d%d?):(%d%d)")
    if not h then return nil end
    return tonumber(h) * 60 + tonumber(m)
end

-- Compute worked hours from a start/end clock pair (handles overnight spans).
local function hours_from_times(start_time, end_time)
    local sm, em = time_to_minutes(start_time), time_to_minutes(end_time)
    if not sm or not em then return nil end
    local diff = em - sm
    if diff < 0 then diff = diff + 24 * 60 end -- crossed midnight
    return math.floor((diff / 60) * 100 + 0.5) / 100
end

-- Coerce a form/string boolean into a real boolean (defaulting when absent).
local function to_bool(v, default_value)
    if v == nil or v == "" then return default_value end
    if type(v) == "boolean" then return v end
    v = tostring(v):lower()
    return v == "true" or v == "1" or v == "yes"
end

-- Treat empty strings as NULL so DATE/TIME/NUMERIC columns don't choke.
local function nilify(v)
    if v == nil or v == "" then return nil end
    return v
end

-- Resolve a customer UUID to its internal id + display name (tenant-scoped).
-- pcall-guarded so timesheets work even when the customers module isn't enabled.
local function resolve_customer(namespace_id, customer_uuid)
    local ok, rows = pcall(function()
        return db.query([[
            SELECT id, first_name, last_name, email FROM customers
            WHERE uuid = ? AND namespace_id = ? LIMIT 1
        ]], customer_uuid, namespace_id)
    end)
    if not ok or not rows or not rows[1] then return nil end
    local c = rows[1]
    local name = ((c.first_name or "") .. " " .. (c.last_name or "")):gsub("^%s+", ""):gsub("%s+$", "")
    if name == "" then name = c.email end
    return { id = c.id, name = name }
end

-- Resolve a kanban task UUID to its title + parent project (tenant-scoped via the
-- project's namespace_id). pcall-guarded so timesheets work without the kanban module.
local function resolve_task(namespace_id, task_uuid)
    local ok, rows = pcall(function()
        return db.query([[
            SELECT t.uuid AS task_uuid, t.title,
                   p.uuid AS project_uuid, p.name AS project_name
            FROM kanban_tasks t
            JOIN kanban_boards b ON b.id = t.board_id
            JOIN kanban_projects p ON p.id = b.project_id
            WHERE t.uuid = ? AND p.namespace_id = ? AND t.deleted_at IS NULL
            LIMIT 1
        ]], task_uuid, namespace_id)
    end)
    if not ok or not rows or not rows[1] then return nil end
    return rows[1]
end

function TimesheetQueries.create(params)
    if not params.uuid then
        params.uuid = Global.generateUUID()
    end

    -- Resolve the customer (ecommerce customers.uuid -> id + name snapshot).
    local customer_uuid = nilify(params.customer_uuid)
    params.customer_uuid = customer_uuid
    if customer_uuid then
        local cust = resolve_customer(params.namespace_id, customer_uuid)
        if cust then
            params.customer_id = cust.id
            if not nilify(params.client_name) then params.client_name = cust.name end
        end
    end

    -- Resolve the task (kanban task.uuid -> title + project), tenant-scoped.
    local task_uuid = nilify(params.task_uuid)
    params.task_uuid = task_uuid
    if task_uuid then
        local t = resolve_task(params.namespace_id, task_uuid)
        if t then
            params.project_uuid = t.project_uuid
            params.project_name = t.project_name
            if not nilify(params.task) then params.task = t.title end
        end
    end
    params.client_account_uuid = nil -- legacy; not a column

    -- Normalise the optional single-session work fields.
    params.work_date   = nilify(params.work_date)
    params.start_time  = nilify(params.start_time)
    params.end_time    = nilify(params.end_time)
    params.task        = nilify(params.task)
    params.client_name = nilify(params.client_name)
    params.hourly_rate = nilify(params.hourly_rate)
    params.is_billable = to_bool(params.is_billable, true)

    -- Hours: derive from start/end time when given, else accept an explicit value.
    local hours = hours_from_times(params.start_time, params.end_time)
        or tonumber(params.total_hours) or 0
    params.total_hours    = hours
    params.billable_hours = params.is_billable and hours or 0

    -- A single-session log only needs a work_date; mirror it into the (NOT NULL)
    -- period columns so the existing period-based reports keep working.
    if not nilify(params.period_start) then params.period_start = params.work_date end
    if not nilify(params.period_end)   then params.period_end   = params.work_date end

    params.status     = "draft"
    params.created_at = db.raw("NOW()")
    params.updated_at = db.raw("NOW()")

    local timesheet = TimesheetModel:create(params, {
        returning = "*"
    })
    timesheet.internal_id = timesheet.id
    timesheet.id = timesheet.uuid
    return timesheet
end

-- Namespace-scoped customer lookup for the timesheet customer dropdown.
-- Returns up to 100 customers (optionally filtered by `q`). Empty list if the
-- customers module isn't enabled.
function TimesheetQueries.lookupCustomers(namespace_id, q)
    local ok, rows = pcall(function()
        local where = "namespace_id = ?"
        local args = { namespace_id }
        if q and q ~= "" then
            where = where .. " AND (first_name ILIKE ? OR last_name ILIKE ? OR email ILIKE ?)"
            local like = "%" .. q .. "%"
            table.insert(args, like); table.insert(args, like); table.insert(args, like)
        end
        table.insert(args, 100)
        return db.query([[
            SELECT uuid, first_name, last_name, email
            FROM customers
            WHERE ]] .. where .. [[
            ORDER BY created_at DESC
            LIMIT ?
        ]], unpack(args))
    end)
    if not ok or not rows then return {} end
    return rows
end

-- Namespace-scoped kanban task lookup (joined to its project) for the task
-- dropdown. Tenant isolation is enforced via the project's namespace_id.
function TimesheetQueries.lookupTasks(namespace_id, q)
    local ok, rows = pcall(function()
        local where = "p.namespace_id = ? AND t.deleted_at IS NULL"
        local args = { namespace_id }
        if q and q ~= "" then
            where = where .. " AND t.title ILIKE ?"
            table.insert(args, "%" .. q .. "%")
        end
        table.insert(args, 100)
        return db.query([[
            SELECT t.uuid AS task_uuid, t.title,
                   p.uuid AS project_uuid, p.name AS project_name
            FROM kanban_tasks t
            JOIN kanban_boards b ON b.id = t.board_id
            JOIN kanban_projects p ON p.id = b.project_id
            WHERE ]] .. where .. [[
            ORDER BY t.updated_at DESC
            LIMIT ?
        ]], unpack(args))
    end)
    if not ok or not rows then return {} end
    return rows
end

function TimesheetQueries.list(namespace_id, params)
    local page = tonumber(params.page) or 1
    local per_page = tonumber(params.per_page) or 10
    local offset = (page - 1) * per_page

    local where_clauses = { "t.namespace_id = ?" }
    local query_params = { namespace_id }

    if params.user_uuid and params.user_uuid ~= "" then
        table.insert(where_clauses, "t.user_uuid = ?")
        table.insert(query_params, params.user_uuid)
    end

    if params.status and params.status ~= "" then
        table.insert(where_clauses, "t.status = ?")
        table.insert(query_params, params.status)
    end

    if params.period_start and params.period_start ~= "" then
        table.insert(where_clauses, "t.period_start >= ?")
        table.insert(query_params, params.period_start)
    end

    if params.period_end and params.period_end ~= "" then
        table.insert(where_clauses, "t.period_end <= ?")
        table.insert(query_params, params.period_end)
    end

    table.insert(where_clauses, "t.deleted_at IS NULL")

    local where_sql = table.concat(where_clauses, " AND ")

    -- Get total count
    local count_query = "SELECT COUNT(*) as total FROM timesheets t WHERE " .. where_sql
    table.insert(query_params, per_page)
    table.insert(query_params, offset)

    -- Build count params (without limit/offset)
    local count_params = {}
    for i = 1, #query_params - 2 do
        count_params[i] = query_params[i]
    end

    local count_result = db.query(count_query, unpack(count_params))
    local total = count_result[1] and tonumber(count_result[1].total) or 0

    -- Get paginated results with user info
    local timesheets = db.query([[
        SELECT
            t.id as internal_id,
            t.uuid as id,
            t.uuid as uuid,
            t.namespace_id,
            t.user_uuid,
            t.notes,
            t.period_start,
            t.period_end,
            t.status,
            t.total_hours,
            t.billable_hours,
            t.client_account_id,
            t.client_name,
            t.task,
            t.work_date,
            t.start_time,
            t.end_time,
            t.hourly_rate,
            t.is_billable,
            t.customer_id,
            t.customer_uuid,
            t.task_uuid,
            t.project_uuid,
            t.project_name,
            t.submitted_at,
            t.approved_at,
            t.rejected_at,
            t.created_at,
            t.updated_at,
            u.username as user_name,
            u.email as user_email
        FROM timesheets t
        LEFT JOIN users u ON t.user_uuid = u.uuid
        WHERE ]] .. where_sql .. [[
        ORDER BY t.created_at DESC
        LIMIT ? OFFSET ?
    ]], unpack(query_params))

    local total_pages = math.ceil(total / per_page)

    return {
        data = timesheets,
        meta = {
            total = total,
            page = page,
            per_page = per_page,
            total_pages = total_pages
        }
    }
end

function TimesheetQueries.get(uuid)
    local results = db.query([[
        SELECT
            t.id as internal_id,
            t.uuid as id,
            t.uuid as uuid,
            t.namespace_id,
            t.user_uuid,
            t.notes,
            t.period_start,
            t.period_end,
            t.status,
            t.total_hours,
            t.billable_hours,
            t.client_account_id,
            t.client_name,
            t.task,
            t.work_date,
            t.start_time,
            t.end_time,
            t.hourly_rate,
            t.is_billable,
            t.customer_id,
            t.customer_uuid,
            t.task_uuid,
            t.project_uuid,
            t.project_name,
            t.submitted_at,
            t.approved_at,
            t.approved_by_uuid,
            t.rejected_at,
            t.rejected_by_uuid,
            t.rejection_reason,
            t.created_at,
            t.updated_at,
            u.username as user_name,
            u.email as user_email
        FROM timesheets t
        LEFT JOIN users u ON t.user_uuid = u.uuid
        WHERE t.uuid = ? AND t.deleted_at IS NULL
        LIMIT 1
    ]], uuid)

    if not results or not results[1] then
        return nil
    end

    local timesheet = results[1]

    -- Get entries
    local entries = db.query([[
        SELECT
            id as internal_id,
            uuid as id,
            timesheet_id,
            entry_date,
            hours,
            is_billable,
            description,
            project_reference,
            category,
            task_reference,
            created_at,
            updated_at
        FROM timesheet_entries
        WHERE timesheet_id = ? AND deleted_at IS NULL
        ORDER BY entry_date ASC, created_at ASC
    ]], timesheet.internal_id)

    timesheet.entries = entries or {}

    -- Get approval history
    local approvals = db.query([[
        SELECT
            ta.id,
            ta.action,
            ta.comments,
            ta.created_at,
            u.username as approver_name,
            u.email as approver_email
        FROM timesheet_approvals ta
        LEFT JOIN users u ON ta.approver_uuid = u.uuid
        WHERE ta.timesheet_id = ?
        ORDER BY ta.created_at ASC
    ]], timesheet.internal_id)

    timesheet.approval_history = approvals or {}

    return timesheet
end

function TimesheetQueries.update(uuid, params, namespace_id)
    local timesheet = TimesheetModel:find({ uuid = uuid })
    if not timesheet then
        return nil, "Timesheet not found"
    end

    -- Tenant ownership guard: never let one namespace edit another's timesheet.
    if namespace_id and tonumber(timesheet.namespace_id) ~= tonumber(namespace_id) then
        return nil, "Timesheet not found"
    end

    if timesheet.status ~= "draft" then
        return nil, "Only draft timesheets can be updated"
    end

    if timesheet.deleted_at then
        return nil, "Timesheet not found"
    end

    params.id = nil
    params.uuid = nil
    params.status = nil
    params.namespace_id = nil
    params.user_uuid = nil

    -- Resolve customer + task the same way create does (tenant-scoped, module-optional).
    local customer_uuid = nilify(params.customer_uuid)
    if customer_uuid then
        params.customer_uuid = customer_uuid
        local cust = resolve_customer(timesheet.namespace_id, customer_uuid)
        if cust then
            params.customer_id = cust.id
            if not nilify(params.client_name) then params.client_name = cust.name end
        end
    end
    local task_uuid = nilify(params.task_uuid)
    if task_uuid then
        params.task_uuid = task_uuid
        local t = resolve_task(timesheet.namespace_id, task_uuid)
        if t then
            params.project_uuid = t.project_uuid
            params.project_name = t.project_name
            if not nilify(params.task) then params.task = t.title end
        end
    end
    params.client_account_uuid = nil -- legacy; not a column

    -- Normalise optional fields and recompute hours when a time span is supplied.
    for _, k in ipairs({ "work_date", "start_time", "end_time", "task", "client_name", "hourly_rate" }) do
        params[k] = nilify(params[k])
    end
    if params.is_billable ~= nil then
        params.is_billable = to_bool(params.is_billable, true)
    end
    local hours = hours_from_times(params.start_time, params.end_time)
    if hours then
        params.total_hours = hours
        local billable = params.is_billable
        if billable == nil then billable = timesheet.is_billable end
        params.billable_hours = billable and hours or 0
    end
    -- Keep the (NOT NULL) period columns in step with a single-session work_date.
    if params.work_date then
        if not nilify(params.period_start) then params.period_start = params.work_date end
        if not nilify(params.period_end)   then params.period_end   = params.work_date end
    end

    params.updated_at = db.raw("NOW()")

    local updated = timesheet:update(params, { returning = "*" })
    updated.internal_id = updated.id
    updated.id = updated.uuid
    return updated
end

function TimesheetQueries.delete(uuid)
    local timesheet = TimesheetModel:find({ uuid = uuid })
    if not timesheet then
        return nil, "Timesheet not found"
    end

    if timesheet.status ~= "draft" then
        return nil, "Only draft timesheets can be deleted"
    end

    timesheet:update({
        deleted_at = db.raw("NOW()"),
        updated_at = db.raw("NOW()")
    })
    return true
end

-- ============================================================
-- WORKFLOW
-- ============================================================

function TimesheetQueries.submit(uuid, user_uuid)
    local timesheet = TimesheetModel:find({ uuid = uuid })
    if not timesheet then
        return nil, "Timesheet not found"
    end

    if timesheet.deleted_at then
        return nil, "Timesheet not found"
    end

    if timesheet.status ~= "draft" then
        return nil, "Only draft timesheets can be submitted"
    end

    if timesheet.user_uuid ~= user_uuid then
        return nil, "You can only submit your own timesheets"
    end

    -- Recalculate totals from entries before submitting
    _recalculate_totals(timesheet.id)

    local updated = timesheet:update({
        status = "submitted",
        submitted_at = db.raw("NOW()"),
        updated_at = db.raw("NOW()")
    }, { returning = "*" })

    updated.internal_id = updated.id
    updated.id = updated.uuid
    return updated
end

function TimesheetQueries.approve(uuid, approver_uuid, comments)
    local timesheet = TimesheetModel:find({ uuid = uuid })
    if not timesheet then
        return nil, "Timesheet not found"
    end

    if timesheet.deleted_at then
        return nil, "Timesheet not found"
    end

    if timesheet.status ~= "submitted" then
        return nil, "Only submitted timesheets can be approved"
    end

    local updated = timesheet:update({
        status = "approved",
        approved_at = db.raw("NOW()"),
        approved_by_uuid = approver_uuid,
        updated_at = db.raw("NOW()")
    }, { returning = "*" })

    -- Create approval record
    TimesheetApprovalModel:create({
        timesheet_id = timesheet.id,
        approver_uuid = approver_uuid,
        action = "approved",
        comments = comments,
        created_at = db.raw("NOW()")
    })

    updated.internal_id = updated.id
    updated.id = updated.uuid
    return updated
end

function TimesheetQueries.reject(uuid, approver_uuid, reason, comments)
    local timesheet = TimesheetModel:find({ uuid = uuid })
    if not timesheet then
        return nil, "Timesheet not found"
    end

    if timesheet.deleted_at then
        return nil, "Timesheet not found"
    end

    if timesheet.status ~= "submitted" then
        return nil, "Only submitted timesheets can be rejected"
    end

    local updated = timesheet:update({
        status = "rejected",
        rejected_at = db.raw("NOW()"),
        rejected_by_uuid = approver_uuid,
        rejection_reason = reason,
        updated_at = db.raw("NOW()")
    }, { returning = "*" })

    -- Create approval record
    TimesheetApprovalModel:create({
        timesheet_id = timesheet.id,
        approver_uuid = approver_uuid,
        action = "rejected",
        comments = comments or reason,
        created_at = db.raw("NOW()")
    })

    updated.internal_id = updated.id
    updated.id = updated.uuid
    return updated
end

function TimesheetQueries.reopen(uuid)
    local timesheet = TimesheetModel:find({ uuid = uuid })
    if not timesheet then
        return nil, "Timesheet not found"
    end

    if timesheet.deleted_at then
        return nil, "Timesheet not found"
    end

    if timesheet.status ~= "rejected" then
        return nil, "Only rejected timesheets can be reopened"
    end

    local updated = timesheet:update({
        status = "draft",
        submitted_at = db.raw("NULL"),
        approved_at = db.raw("NULL"),
        approved_by_uuid = db.raw("NULL"),
        rejected_at = db.raw("NULL"),
        rejected_by_uuid = db.raw("NULL"),
        rejection_reason = db.raw("NULL"),
        updated_at = db.raw("NOW()")
    }, { returning = "*" })

    updated.internal_id = updated.id
    updated.id = updated.uuid
    return updated
end

function TimesheetQueries.getApprovalQueue(namespace_id, approver_uuid, params)
    local page = tonumber(params.page) or 1
    local per_page = tonumber(params.per_page) or 10
    local offset = (page - 1) * per_page

    local count_result = db.query([[
        SELECT COUNT(*) as total
        FROM timesheets t
        WHERE t.namespace_id = ?
          AND t.status = 'submitted'
          AND t.deleted_at IS NULL
    ]], namespace_id)
    local total = count_result[1] and tonumber(count_result[1].total) or 0

    local timesheets = db.query([[
        SELECT
            t.id as internal_id,
            t.uuid as id,
            t.uuid as uuid,
            t.namespace_id,
            t.user_uuid,
            t.notes,
            t.period_start,
            t.period_end,
            t.status,
            t.total_hours,
            t.billable_hours,
            t.submitted_at,
            t.created_at,
            u.username as user_name,
            u.email as user_email
        FROM timesheets t
        LEFT JOIN users u ON t.user_uuid = u.uuid
        WHERE t.namespace_id = ?
          AND t.status = 'submitted'
          AND t.deleted_at IS NULL
        ORDER BY t.submitted_at ASC
        LIMIT ? OFFSET ?
    ]], namespace_id, per_page, offset)

    local total_pages = math.ceil(total / per_page)

    return {
        data = timesheets,
        meta = {
            total = total,
            page = page,
            per_page = per_page,
            total_pages = total_pages
        }
    }
end

function TimesheetQueries.getMyTimesheets(namespace_id, user_uuid, params)
    local page = tonumber(params.page) or 1
    local per_page = tonumber(params.per_page) or 10
    local offset = (page - 1) * per_page

    local where_clauses = { "t.namespace_id = ?", "t.user_uuid = ?", "t.deleted_at IS NULL" }
    local query_params = { namespace_id, user_uuid }

    if params.status and params.status ~= "" then
        table.insert(where_clauses, "t.status = ?")
        table.insert(query_params, params.status)
    end

    local where_sql = table.concat(where_clauses, " AND ")

    local count_params = {}
    for i = 1, #query_params do
        count_params[i] = query_params[i]
    end

    local count_result = db.query(
        "SELECT COUNT(*) as total FROM timesheets t WHERE " .. where_sql,
        unpack(count_params)
    )
    local total = count_result[1] and tonumber(count_result[1].total) or 0

    table.insert(query_params, per_page)
    table.insert(query_params, offset)

    local timesheets = db.query([[
        SELECT
            t.id as internal_id,
            t.uuid as id,
            t.uuid as uuid,
            t.namespace_id,
            t.user_uuid,
            t.notes,
            t.period_start,
            t.period_end,
            t.status,
            t.total_hours,
            t.billable_hours,
            t.client_account_id,
            t.client_name,
            t.task,
            t.work_date,
            t.start_time,
            t.end_time,
            t.hourly_rate,
            t.is_billable,
            t.customer_id,
            t.customer_uuid,
            t.task_uuid,
            t.project_uuid,
            t.project_name,
            t.submitted_at,
            t.approved_at,
            t.rejected_at,
            t.created_at,
            t.updated_at
        FROM timesheets t
        WHERE ]] .. where_sql .. [[
        ORDER BY t.created_at DESC
        LIMIT ? OFFSET ?
    ]], unpack(query_params))

    local total_pages = math.ceil(total / per_page)

    return {
        data = timesheets,
        meta = {
            total = total,
            page = page,
            per_page = per_page,
            total_pages = total_pages
        }
    }
end

function TimesheetQueries.getSummary(namespace_id, user_uuid, start_date, end_date)
    local where_clauses = { "t.namespace_id = ?", "t.deleted_at IS NULL" }
    local query_params = { namespace_id }

    if user_uuid and user_uuid ~= "" then
        table.insert(where_clauses, "t.user_uuid = ?")
        table.insert(query_params, user_uuid)
    end

    if start_date and start_date ~= "" then
        table.insert(where_clauses, "t.period_start >= ?")
        table.insert(query_params, start_date)
    end

    if end_date and end_date ~= "" then
        table.insert(where_clauses, "t.period_end <= ?")
        table.insert(query_params, end_date)
    end

    local where_sql = table.concat(where_clauses, " AND ")

    -- Overall summary
    local summary = db.query([[
        SELECT
            COALESCE(SUM(t.total_hours), 0) as total_hours,
            COALESCE(SUM(t.billable_hours), 0) as billable_hours,
            COUNT(*) as total_timesheets,
            COUNT(CASE WHEN t.status = 'draft' THEN 1 END) as draft_count,
            COUNT(CASE WHEN t.status = 'submitted' THEN 1 END) as submitted_count,
            COUNT(CASE WHEN t.status = 'approved' THEN 1 END) as approved_count,
            COUNT(CASE WHEN t.status = 'rejected' THEN 1 END) as rejected_count
        FROM timesheets t
        WHERE ]] .. where_sql,
        unpack(query_params)
    )

    -- By project breakdown
    local by_project_params = {}
    for i = 1, #query_params do
        by_project_params[i] = query_params[i]
    end

    local by_project = db.query([[
        SELECT
            te.project_reference,
            COALESCE(SUM(te.hours), 0) as total_hours,
            COALESCE(SUM(CASE WHEN te.is_billable = true THEN te.hours ELSE 0 END), 0) as billable_hours
        FROM timesheet_entries te
        JOIN timesheets t ON te.timesheet_id = t.id
        WHERE ]] .. where_sql .. [[ AND te.deleted_at IS NULL
        GROUP BY te.project_reference
        ORDER BY total_hours DESC
    ]], unpack(by_project_params))

    -- By category breakdown
    local by_category_params = {}
    for i = 1, #query_params do
        by_category_params[i] = query_params[i]
    end

    local by_category = db.query([[
        SELECT
            te.category,
            COALESCE(SUM(te.hours), 0) as total_hours,
            COALESCE(SUM(CASE WHEN te.is_billable = true THEN te.hours ELSE 0 END), 0) as billable_hours
        FROM timesheet_entries te
        JOIN timesheets t ON te.timesheet_id = t.id
        WHERE ]] .. where_sql .. [[ AND te.deleted_at IS NULL
        GROUP BY te.category
        ORDER BY total_hours DESC
    ]], unpack(by_category_params))

    return {
        summary = summary[1],
        by_project = by_project or {},
        by_category = by_category or {}
    }
end

-- ============================================================
-- ENTRY CRUD
-- ============================================================

function TimesheetQueries.createEntry(params)
    -- Validate hours
    local hours = tonumber(params.hours)
    if not hours or hours < 0 or hours > 24 then
        return nil, "Hours must be between 0 and 24"
    end

    -- Validate parent timesheet exists and is draft
    local timesheet = TimesheetModel:find(params.timesheet_id)
    if not timesheet then
        return nil, "Timesheet not found"
    end

    if timesheet.deleted_at then
        return nil, "Timesheet not found"
    end

    if timesheet.status ~= "draft" then
        return nil, "Entries can only be added to draft timesheets"
    end

    if not params.uuid then
        params.uuid = Global.generateUUID()
    end
    params.created_at = db.raw("NOW()")
    params.updated_at = db.raw("NOW()")

    local entry = TimesheetEntryModel:create(params, {
        returning = "*"
    })

    -- Recalculate timesheet totals
    _recalculate_totals(params.timesheet_id)

    entry.internal_id = entry.id
    entry.id = entry.uuid
    return entry
end

function TimesheetQueries.updateEntry(uuid, params)
    local entry = TimesheetEntryModel:find({ uuid = uuid })
    if not entry then
        return nil, "Entry not found"
    end

    if entry.deleted_at then
        return nil, "Entry not found"
    end

    -- Validate parent timesheet is draft
    local timesheet = TimesheetModel:find(entry.timesheet_id)
    if not timesheet or timesheet.status ~= "draft" then
        return nil, "Entries can only be updated on draft timesheets"
    end

    -- Validate hours if provided
    if params.hours then
        local hours = tonumber(params.hours)
        if not hours or hours < 0 or hours > 24 then
            return nil, "Hours must be between 0 and 24"
        end
    end

    params.id = nil
    params.uuid = nil
    params.timesheet_id = nil
    params.updated_at = db.raw("NOW()")

    local updated = entry:update(params, { returning = "*" })

    -- Recalculate timesheet totals
    _recalculate_totals(entry.timesheet_id)

    updated.internal_id = updated.id
    updated.id = updated.uuid
    return updated
end

function TimesheetQueries.deleteEntry(uuid)
    local entry = TimesheetEntryModel:find({ uuid = uuid })
    if not entry then
        return nil, "Entry not found"
    end

    if entry.deleted_at then
        return nil, "Entry not found"
    end

    -- Validate parent timesheet is draft
    local timesheet = TimesheetModel:find(entry.timesheet_id)
    if not timesheet or timesheet.status ~= "draft" then
        return nil, "Entries can only be deleted from draft timesheets"
    end

    entry:update({
        deleted_at = db.raw("NOW()"),
        updated_at = db.raw("NOW()")
    })

    -- Recalculate timesheet totals
    _recalculate_totals(entry.timesheet_id)

    return true
end

function TimesheetQueries.getEntriesByTimesheet(timesheet_id)
    local entries = db.query([[
        SELECT
            id as internal_id,
            uuid as id,
            timesheet_id,
            entry_date,
            hours,
            is_billable,
            description,
            project_reference,
            category,
            task_reference,
            created_at,
            updated_at
        FROM timesheet_entries
        WHERE timesheet_id = ? AND deleted_at IS NULL
        ORDER BY entry_date ASC, created_at ASC
    ]], timesheet_id)

    return entries or {}
end

function TimesheetQueries.getEntriesByDate(namespace_id, user_uuid, date)
    local entries = db.query([[
        SELECT
            te.id as internal_id,
            te.uuid as id,
            te.timesheet_id,
            te.entry_date,
            te.hours,
            te.is_billable,
            te.description,
            te.project_reference,
            te.category,
            te.task_reference,
            te.created_at,
            te.updated_at,
            t.uuid as timesheet_uuid,
            t.notes as timesheet_title
        FROM timesheet_entries te
        JOIN timesheets t ON te.timesheet_id = t.id
        WHERE t.namespace_id = ?
          AND t.user_uuid = ?
          AND te.entry_date = ?
          AND te.deleted_at IS NULL
          AND t.deleted_at IS NULL
        ORDER BY te.created_at ASC
    ]], namespace_id, user_uuid, date)

    return entries or {}
end

return TimesheetQueries
