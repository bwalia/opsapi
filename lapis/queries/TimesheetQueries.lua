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
            COALESCE(SUM(CASE WHEN billable = true THEN hours ELSE 0 END), 0) as billable_hours
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

function TimesheetQueries.create(params)
    if not params.uuid then
        params.uuid = Global.generateUUID()
    end
    params.status = "draft"
    params.total_hours = 0
    params.billable_hours = 0
    params.created_at = db.raw("NOW()")
    params.updated_at = db.raw("NOW()")

    local timesheet = TimesheetModel:create(params, {
        returning = "*"
    })
    timesheet.internal_id = timesheet.id
    timesheet.id = timesheet.uuid
    return timesheet
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
            t.namespace_id,
            t.user_uuid,
            t.title,
            t.description,
            t.period_start,
            t.period_end,
            t.status,
            t.total_hours,
            t.billable_hours,
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
            t.namespace_id,
            t.user_uuid,
            t.title,
            t.description,
            t.period_start,
            t.period_end,
            t.status,
            t.total_hours,
            t.billable_hours,
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
            billable,
            description,
            project_uuid,
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

function TimesheetQueries.update(uuid, params)
    local timesheet = TimesheetModel:find({ uuid = uuid })
    if not timesheet then
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
            t.namespace_id,
            t.user_uuid,
            t.title,
            t.description,
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
            t.namespace_id,
            t.user_uuid,
            t.title,
            t.description,
            t.period_start,
            t.period_end,
            t.status,
            t.total_hours,
            t.billable_hours,
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
            te.project_uuid,
            COALESCE(SUM(te.hours), 0) as total_hours,
            COALESCE(SUM(CASE WHEN te.billable = true THEN te.hours ELSE 0 END), 0) as billable_hours
        FROM timesheet_entries te
        JOIN timesheets t ON te.timesheet_id = t.id
        WHERE ]] .. where_sql .. [[ AND te.deleted_at IS NULL
        GROUP BY te.project_uuid
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
            COALESCE(SUM(CASE WHEN te.billable = true THEN te.hours ELSE 0 END), 0) as billable_hours
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
            billable,
            description,
            project_uuid,
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
            te.billable,
            te.description,
            te.project_uuid,
            te.category,
            te.task_reference,
            te.created_at,
            te.updated_at,
            t.uuid as timesheet_uuid,
            t.title as timesheet_title
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
