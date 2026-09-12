--[[
    Field Service — engineer site visit queries
    ===========================================

    Visits are booked against a job (optionally a specific phase) for one
    engineer. Lifecycle:

        scheduled -> en_route -> on_site (check-in) -> completed (check-out)
        scheduled / en_route / on_site -> no_access
        scheduled / en_route -> cancelled

    Check-out records the work report + labour hours, can complete the linked
    phase (carrying the customer's sign-off), and logs the hours to the
    engineer's timesheet. Labour hours default to check-out minus check-in.
]]

local db = require("lapis.db")
local cjson = require("cjson")
local FsVisitModel = require("models.FsVisitModel")
local Common = require("queries.FieldServiceCommon")
local JobQueries = require("queries.FieldServiceJobQueries")
local ProjectConfig = require("helper.project-config")

local nilify, nullable, to_bool, to_number, arr, round2 =
    Common.nilify, Common.nullable, Common.to_bool, Common.to_number, Common.arr, Common.round2

local VisitQueries = {}

local OPEN = { scheduled = true, en_route = true, on_site = true }

--------------------------------------------------------------------------------
-- Lookups
--------------------------------------------------------------------------------

function VisitQueries.findVisitRow(namespace_id, uuid)
    if not nilify(uuid) then return nil end
    local rows = db.query([[
        SELECT * FROM fs_visits WHERE uuid = ? AND namespace_id = ? AND deleted_at IS NULL LIMIT 1
    ]], tostring(uuid), namespace_id)
    return rows and rows[1]
end

--- Full visit: visit + job/site/customer context + the linked phase (with its
-- checklist, so the engineer can tick it on site) + items logged on the visit.
function VisitQueries.getVisit(namespace_id, uuid)
    local rows = db.query(JobQueries.VISIT_SELECT ..
        " WHERE v.uuid = ? AND v.namespace_id = ? AND v.deleted_at IS NULL LIMIT 1", tostring(uuid), namespace_id)
    local row = rows and rows[1]
    if not row then return nil end

    local visit = JobQueries.shapeVisit(row)
    visit.phase = row.phase_uuid and JobQueries.getPhase(namespace_id, row.phase_uuid) or nil
    local items = {}
    for _, it in ipairs(JobQueries.listItems(row.job_id)) do
        if it.visit_uuid == row.uuid then table.insert(items, it) end
    end
    visit.items = arr(items)
    return visit
end

function VisitQueries.listVisits(namespace_id, params)
    params = params or {}
    local page, per_page, offset = Common.paging(params)
    local where = { "v.namespace_id = ?", "v.deleted_at IS NULL", "j.deleted_at IS NULL" }
    local values = { namespace_id }

    local function add(cond, value)
        table.insert(where, cond)
        if value ~= nil then table.insert(values, value) end
    end

    if nilify(params.job_uuid) then add("j.uuid = ?", tostring(params.job_uuid)) end
    local engineer = nilify(params.engineer_uuid)
    if engineer == "unassigned" then
        add("v.engineer_user_uuid IS NULL")
    elseif engineer then
        add("v.engineer_user_uuid = ?", tostring(engineer))
    end
    local status = nilify(params.status)
    if status == "open" then
        add("v.status IN ('scheduled', 'en_route', 'on_site')")
    elseif status and status ~= "all" then
        add("v.status = ?", tostring(status))
    end
    if nilify(params.from) then add("v.scheduled_start >= ?::timestamp", tostring(params.from)) end
    if nilify(params.to) then add("v.scheduled_start < ?::timestamp", tostring(params.to)) end
    if to_bool(params.follow_up, false) then add("v.follow_up_required = true") end
    if nilify(params.search) then
        local term = "%" .. tostring(params.search) .. "%"
        add("(j.job_number ILIKE ? OR j.title ILIKE ? OR a.name ILIKE ? OR s.postal_code ILIKE ?)")
        for _ = 1, 4 do table.insert(values, term) end
    end
    local where_sql = table.concat(where, " AND ")
    local order_dir = tostring(params.order_dir or ""):lower() == "desc" and "DESC" or "ASC"

    local count = db.query([[
        SELECT COUNT(*) AS total FROM fs_visits v
        JOIN fs_jobs j ON j.id = v.job_id
        LEFT JOIN crm_accounts a ON a.id = j.account_id
        LEFT JOIN fs_sites s ON s.id = j.site_id
        WHERE ]] .. where_sql, unpack(values))

    local page_values = { unpack(values) }
    table.insert(page_values, per_page)
    table.insert(page_values, offset)
    local rows = db.query(JobQueries.VISIT_SELECT .. " WHERE " .. where_sql ..
        " ORDER BY v.scheduled_start " .. order_dir .. ", v.id " .. order_dir .. " LIMIT ? OFFSET ?",
        unpack(page_values))

    local items = {}
    for _, v in ipairs(rows or {}) do table.insert(items, JobQueries.shapeVisit(v)) end
    return { items = arr(items), meta = Common.meta(count[1].total, page, per_page) }
end

--------------------------------------------------------------------------------
-- Scheduling helpers
--------------------------------------------------------------------------------

-- Validate timestamps via Postgres (accepts ISO-8601; the "Z" is dropped).
local function check_range(start_at, end_at)
    local ok, rows = pcall(db.query, "SELECT (?::timestamp < COALESCE(?::timestamp, 'infinity')) AS ok",
        tostring(start_at), end_at and tostring(end_at) or db.NULL)
    if not ok then return nil, "Invalid date/time — use ISO-8601 (e.g. 2026-09-14T09:00:00Z)" end
    if not rows[1].ok then return nil, "scheduled_end must be after scheduled_start" end
    return true
end

--- Other open visits the engineer has overlapping this slot (visits without an
-- end are treated as one hour long). Informational — booking still succeeds.
function VisitQueries.findConflicts(namespace_id, engineer_uuid, start_at, end_at, exclude_id)
    if not nilify(engineer_uuid) or not nilify(start_at) then return arr({}) end
    local rows = db.query([[
        SELECT v.uuid, v.scheduled_start, v.scheduled_end, j.job_number, j.title AS job_title
        FROM fs_visits v
        JOIN fs_jobs j ON j.id = v.job_id AND j.deleted_at IS NULL
        WHERE v.namespace_id = ? AND v.engineer_user_uuid = ? AND v.deleted_at IS NULL
          AND v.status IN ('scheduled', 'en_route', 'on_site') AND v.id <> ?
          AND tsrange(v.scheduled_start, COALESCE(v.scheduled_end, v.scheduled_start + interval '1 hour'))
              && tsrange(?::timestamp, COALESCE(?::timestamp, ?::timestamp + interval '1 hour'))
        ORDER BY v.scheduled_start
    ]], namespace_id, tostring(engineer_uuid), exclude_id or 0,
        tostring(start_at), end_at and tostring(end_at) or db.NULL, tostring(start_at))
    return arr(rows or {})
end

local function resolve_phase(namespace_id, phase_uuid, job_id)
    local phase = JobQueries.findPhaseRow(namespace_id, phase_uuid)
    if not phase then return nil, "Phase not found" end
    if phase.job_id ~= job_id then return nil, "Phase does not belong to this job" end
    return phase.id
end

--------------------------------------------------------------------------------
-- Create / update / delete
--------------------------------------------------------------------------------

--- Book a visit on a job.
-- @return { visit, conflicts } | nil, err
function VisitQueries.createVisit(namespace_id, job_uuid, data, actor_uuid)
    local job = JobQueries.findJobRow(namespace_id, job_uuid)
    local ok, err = JobQueries.assertJobOpen(job)
    if not ok then return nil, err end

    local start_at, end_at = nilify(data.scheduled_start), nilify(data.scheduled_end)
    if not start_at then return nil, "scheduled_start is required" end
    ok, err = check_range(start_at, end_at)
    if not ok then return nil, err end

    local engineer = nilify(data.engineer_user_uuid)
    if engineer and not Common.is_member(namespace_id, engineer) then
        return nil, "Engineer is not a member of this workspace"
    end

    local phase_id
    if nilify(data.phase_uuid) then
        phase_id, err = resolve_phase(namespace_id, data.phase_uuid, job.id)
        if not phase_id then return nil, err end
    end

    local visit = FsVisitModel:create({
        uuid = Common.uuid(),
        namespace_id = namespace_id,
        job_id = job.id,
        phase_id = phase_id,
        engineer_user_uuid = engineer,
        status = "scheduled",
        scheduled_start = tostring(start_at),
        scheduled_end = end_at and tostring(end_at) or nil,
        instructions = nilify(data.instructions),
        is_billable = to_bool(data.is_billable, true),
        hourly_rate = to_number(data.hourly_rate),
        created_by_uuid = actor_uuid,
    })

    JobQueries.markJobScheduled(job, actor_uuid)
    Common.log_activity(namespace_id, job.id, actor_uuid, "visit_scheduled",
        "Visit booked for " .. tostring(start_at):sub(1, 16):gsub("T", " "), { visit_uuid = visit.uuid })

    return {
        visit = VisitQueries.getVisit(namespace_id, visit.uuid),
        conflicts = VisitQueries.findConflicts(namespace_id, engineer, start_at, end_at, visit.id),
    }
end

--- Update a visit. Schedule/engineer changes only while the visit is still
-- scheduled or en route; the work report can be corrected after completion
-- (labour hours are locked once invoiced, and synced to a draft timesheet).
-- @return { visit, conflicts, warnings } | nil, err
function VisitQueries.updateVisit(namespace_id, uuid, data, actor_uuid)
    local visit = VisitQueries.findVisitRow(namespace_id, uuid)
    if not visit then return nil, "Visit not found" end
    local update, warnings = {}, {}
    local pre_start = visit.status == "scheduled" or visit.status == "en_route"

    local reschedule = data.scheduled_start ~= nil or data.scheduled_end ~= nil or data.engineer_user_uuid ~= nil
    if reschedule and not pre_start then
        return nil, "Only scheduled or en-route visits can be rescheduled or reassigned"
    end

    if data.scheduled_start ~= nil then
        if not nilify(data.scheduled_start) then return nil, "scheduled_start cannot be empty" end
        update.scheduled_start = tostring(data.scheduled_start)
    end
    if data.scheduled_end ~= nil then update.scheduled_end = nullable(data.scheduled_end) end
    if update.scheduled_start or update.scheduled_end then
        local s = update.scheduled_start or visit.scheduled_start
        local e = update.scheduled_end
        if e == nil then e = visit.scheduled_end elseif e == db.NULL then e = nil end
        local ok, err = check_range(s, e)
        if not ok then return nil, err end
    end
    if data.engineer_user_uuid ~= nil then
        local engineer = nilify(data.engineer_user_uuid)
        if engineer and not Common.is_member(namespace_id, engineer) then
            return nil, "Engineer is not a member of this workspace"
        end
        update.engineer_user_uuid = engineer or db.NULL
    end
    if data.phase_uuid ~= nil then
        if nilify(data.phase_uuid) then
            local phase_id, err = resolve_phase(namespace_id, data.phase_uuid, visit.job_id)
            if not phase_id then return nil, err end
            update.phase_id = phase_id
        else
            update.phase_id = db.NULL
        end
    end
    for _, f in ipairs({ "instructions", "work_summary", "follow_up_notes", "customer_signoff_name" }) do
        if data[f] ~= nil then update[f] = nullable(data[f]) end
    end
    if data.follow_up_required ~= nil then update.follow_up_required = to_bool(data.follow_up_required, false) end

    local invoiced = visit.invoice_line_item_id ~= nil
    if data.is_billable ~= nil or data.hourly_rate ~= nil or data.labour_hours ~= nil then
        if invoiced then return nil, "Visit has been invoiced — billing fields are locked" end
        if data.is_billable ~= nil then update.is_billable = to_bool(data.is_billable, true) end
        if data.hourly_rate ~= nil then update.hourly_rate = to_number(data.hourly_rate) or db.NULL end
        if data.labour_hours ~= nil then
            local h = to_number(data.labour_hours)
            if h and (h < 0 or h > 24) then return nil, "labour_hours must be between 0 and 24" end
            update.labour_hours = h and round2(h) or db.NULL
        end
    end
    if next(update) == nil then return nil, "No valid fields to update" end

    FsVisitModel:find(visit.id):update(update)

    -- Keep the engineer's (still draft) timesheet entry in step with the hours.
    if type(update.labour_hours) == "number" and visit.timesheet_entry_id then
        local entry = db.query("SELECT uuid FROM timesheet_entries WHERE id = ?", visit.timesheet_entry_id)[1]
        if entry then
            local TimesheetQueries = require("queries.TimesheetQueries")
            local ok, err = TimesheetQueries.updateEntry(entry.uuid, { hours = update.labour_hours }, namespace_id)
            if not ok then table.insert(warnings, "Timesheet not updated: " .. tostring(err)) end
        end
    end

    local fresh = VisitQueries.findVisitRow(namespace_id, uuid)
    Common.log_activity(namespace_id, visit.job_id, actor_uuid, "visit_updated", "Visit updated",
        { visit_uuid = visit.uuid })
    return {
        visit = VisitQueries.getVisit(namespace_id, uuid),
        conflicts = OPEN[fresh.status] and VisitQueries.findConflicts(namespace_id, fresh.engineer_user_uuid,
            fresh.scheduled_start, fresh.scheduled_end, fresh.id) or arr({}),
        warnings = arr(warnings),
    }
end

function VisitQueries.deleteVisit(namespace_id, uuid, actor_uuid)
    local visit = VisitQueries.findVisitRow(namespace_id, uuid)
    if not visit then return nil, "Visit not found" end
    if visit.invoice_line_item_id then return nil, "Visit has been invoiced and cannot be deleted" end
    if visit.timesheet_uuid then return nil, "Visit has been logged to a timesheet — cancel it instead" end
    if visit.status == "on_site" then return nil, "Engineer is on site — check out or mark no access first" end
    db.query("UPDATE fs_visits SET deleted_at = NOW(), updated_at = NOW() WHERE id = ?", visit.id)
    Common.log_activity(namespace_id, visit.job_id, actor_uuid, "visit_deleted", "Visit deleted",
        { visit_uuid = visit.uuid })
    return true
end

--------------------------------------------------------------------------------
-- Engineer workflow
--------------------------------------------------------------------------------

local function transition_guard(visit, allowed, action)
    if not visit then return nil, "Visit not found" end
    if not allowed[visit.status] then
        return nil, "Cannot " .. action .. " a visit that is " .. visit.status:gsub("_", " ")
    end
    return true
end

function VisitQueries.markEnRoute(namespace_id, uuid, actor_uuid)
    local visit = VisitQueries.findVisitRow(namespace_id, uuid)
    local ok, err = transition_guard(visit, { scheduled = true }, "set en route")
    if not ok then return nil, err end
    FsVisitModel:find(visit.id):update({ status = "en_route" })
    Common.log_activity(namespace_id, visit.job_id, actor_uuid, "visit_en_route", "Engineer en route",
        { visit_uuid = visit.uuid })
    return VisitQueries.getVisit(namespace_id, uuid)
end

--- Engineer arrives on site. Starts the job (and the linked phase).
function VisitQueries.checkIn(namespace_id, uuid, data, actor_uuid)
    local visit = VisitQueries.findVisitRow(namespace_id, uuid)
    local ok, err = transition_guard(visit, { scheduled = true, en_route = true }, "check in to")
    if not ok then return nil, err end

    FsVisitModel:find(visit.id):update({
        status = "on_site",
        checked_in_at = db.raw("NOW()"),
        check_in_lat = to_number(data.latitude),
        check_in_lng = to_number(data.longitude),
        engineer_user_uuid = visit.engineer_user_uuid or actor_uuid,
    })

    local job = JobQueries.findJobById(visit.job_id)
    JobQueries.markJobStarted(job, actor_uuid)
    if visit.phase_id then
        local phase = db.query("SELECT uuid, status FROM fs_job_phases WHERE id = ?", visit.phase_id)[1]
        if phase and phase.status == "pending" then
            JobQueries.setPhaseStatus(namespace_id, phase.uuid, "in_progress", {}, actor_uuid)
        end
    end
    Common.log_activity(namespace_id, visit.job_id, actor_uuid, "visit_checked_in", "Engineer checked in on site",
        { visit_uuid = visit.uuid })
    return VisitQueries.getVisit(namespace_id, uuid)
end

--- Log a completed visit's labour to the engineer's timesheet (one draft
-- timesheet per visit, one entry). Idempotent: a visit is only logged once.
function VisitQueries.logTimesheet(namespace_id, uuid, actor_uuid)
    if not ProjectConfig.isTimesheetsEnabled() then return nil, "Timesheets are not enabled" end
    local rows = db.query([[
        SELECT v.*, j.job_number, j.title AS job_title, j.account_id, a.name AS account_name,
            j.hourly_rate AS job_hourly_rate, jt.default_hourly_rate AS job_type_hourly_rate,
            p.name AS phase_name,
            TO_CHAR(COALESCE(v.checked_in_at, v.scheduled_start), 'YYYY-MM-DD') AS work_date
        FROM fs_visits v
        JOIN fs_jobs j ON j.id = v.job_id
        LEFT JOIN fs_job_types jt ON jt.id = j.job_type_id
        LEFT JOIN crm_accounts a ON a.id = j.account_id
        LEFT JOIN fs_job_phases p ON p.id = v.phase_id AND p.deleted_at IS NULL
        WHERE v.uuid = ? AND v.namespace_id = ? AND v.deleted_at IS NULL LIMIT 1
    ]], tostring(uuid), namespace_id)
    local v = rows and rows[1]
    if not v then return nil, "Visit not found" end
    if v.status ~= "completed" then return nil, "Only completed visits can be logged to a timesheet" end
    if v.timesheet_uuid then return nil, "Visit is already logged to timesheet " .. v.timesheet_uuid end
    if not v.engineer_user_uuid then return nil, "Visit has no engineer" end
    local hours = tonumber(v.labour_hours)
    if not hours or hours <= 0 then return nil, "Visit has no labour hours" end

    local TimesheetQueries = require("queries.TimesheetQueries")
    local rate = JobQueries.visitRate(v)
    local task = v.job_number .. " · " .. v.job_title

    return Common.transaction(function()
        -- Created without hours so it gets no seed entry; the single entry is
        -- added below (tagged source=field_service).
        local ts = TimesheetQueries.create({
            namespace_id = namespace_id,
            user_uuid = v.engineer_user_uuid,
            work_date = v.work_date,
            client_account_id = v.account_id,
            client_name = v.account_name,
            task = task,
            hourly_rate = rate,
            is_billable = v.is_billable,
            notes = "Site visit" .. (v.work_summary and (": " .. v.work_summary) or ""),
            metadata = cjson.encode({ source = "field_service", job_number = v.job_number, visit_uuid = v.uuid }),
        })
        if not ts then return nil, "Could not create timesheet" end

        local entry, entry_err = TimesheetQueries.createEntry({
            timesheet_id = ts.internal_id,
            namespace_id = namespace_id,
            user_uuid = v.engineer_user_uuid,
            entry_date = v.work_date,
            hours = hours,
            is_billable = v.is_billable,
            description = v.work_summary or ("Site visit — " .. task),
            project_reference = v.job_number,
            task_reference = v.phase_name or v.job_title,
            hourly_rate = rate,
            source = "field_service",
        })
        if not entry then return nil, entry_err or "Could not add timesheet entry" end

        db.query("UPDATE fs_visits SET timesheet_uuid = ?, timesheet_entry_id = ?, updated_at = NOW() WHERE id = ?",
            ts.id, entry.internal_id, v.id)
        Common.log_activity(namespace_id, v.job_id, actor_uuid, "timesheet_logged",
            string.format("%.2f h logged to timesheet", hours), { visit_uuid = v.uuid, timesheet_uuid = ts.id })
        return { timesheet_uuid = ts.id, hours = hours }
    end)
end

--- Engineer leaves site with the work done.
-- @param data table { work_summary, labour_hours?, latitude?, longitude?,
--   customer_signoff_name?, follow_up_required?, follow_up_notes?,
--   complete_phase?, force_phase?, log_timesheet? (default true) }
-- @return { visit, warnings } | nil, err
function VisitQueries.checkOut(namespace_id, uuid, data, actor_uuid)
    local visit = VisitQueries.findVisitRow(namespace_id, uuid)
    local ok, err = transition_guard(visit, OPEN, "check out of")
    if not ok then return nil, err end

    local hours = to_number(data.labour_hours)
    if not hours then
        if not visit.checked_in_at then
            return nil, "labour_hours is required when the engineer did not check in"
        end
        local r = db.query("SELECT EXTRACT(EPOCH FROM (NOW() - ?::timestamp)) / 3600.0 AS h",
            tostring(visit.checked_in_at))
        hours = tonumber(r[1].h) or 0
    end
    if hours < 0 or hours > 24 then return nil, "labour_hours must be between 0 and 24" end
    if not visit.engineer_user_uuid and not actor_uuid then return nil, "Visit has no engineer" end

    local signoff = nilify(data.customer_signoff_name)
    FsVisitModel:find(visit.id):update({
        status = "completed",
        checked_out_at = db.raw("NOW()"),
        check_out_lat = to_number(data.latitude),
        check_out_lng = to_number(data.longitude),
        labour_hours = round2(hours),
        work_summary = nilify(data.work_summary),
        customer_signoff_name = signoff,
        customer_signed_at = signoff and db.raw("NOW()") or nil,
        follow_up_required = to_bool(data.follow_up_required, false),
        follow_up_notes = nilify(data.follow_up_notes),
        engineer_user_uuid = visit.engineer_user_uuid or actor_uuid,
    })

    local warnings = {}
    JobQueries.markJobStarted(JobQueries.findJobById(visit.job_id), actor_uuid)

    if to_bool(data.complete_phase, false) then
        if not visit.phase_id then
            table.insert(warnings, "Visit is not linked to a phase — nothing to complete")
        else
            local phase = db.query("SELECT uuid FROM fs_job_phases WHERE id = ?", visit.phase_id)[1]
            local done, perr = phase and JobQueries.setPhaseStatus(namespace_id, phase.uuid, "completed", {
                signoff_name = signoff,
                force = data.force_phase,
            }, actor_uuid)
            if not done then table.insert(warnings, "Phase not completed: " .. tostring(perr or "phase not found")) end
        end
    end

    Common.log_activity(namespace_id, visit.job_id, actor_uuid, "visit_completed",
        string.format("Visit completed — %.2f h on site", round2(hours)), { visit_uuid = visit.uuid })

    if to_bool(data.log_timesheet, true) and ProjectConfig.isTimesheetsEnabled() and hours > 0 then
        local logged, terr = VisitQueries.logTimesheet(namespace_id, uuid, actor_uuid)
        if not logged then table.insert(warnings, "Timesheet not logged: " .. tostring(terr)) end
    end

    return { visit = VisitQueries.getVisit(namespace_id, uuid), warnings = arr(warnings) }
end

--- Engineer could not get in. Flags the visit for follow-up.
function VisitQueries.markNoAccess(namespace_id, uuid, data, actor_uuid)
    local visit = VisitQueries.findVisitRow(namespace_id, uuid)
    local ok, err = transition_guard(visit, OPEN, "mark no access on")
    if not ok then return nil, err end
    local reason = nilify(data.reason) or nilify(data.follow_up_notes) or "No access to site"
    FsVisitModel:find(visit.id):update({
        status = "no_access",
        checked_out_at = visit.checked_in_at and db.raw("NOW()") or nil,
        follow_up_required = true,
        follow_up_notes = tostring(reason),
    })
    Common.log_activity(namespace_id, visit.job_id, actor_uuid, "visit_no_access", "No access: " .. tostring(reason),
        { visit_uuid = visit.uuid })
    return VisitQueries.getVisit(namespace_id, uuid)
end

function VisitQueries.cancelVisit(namespace_id, uuid, data, actor_uuid)
    local visit = VisitQueries.findVisitRow(namespace_id, uuid)
    local ok, err = transition_guard(visit, { scheduled = true, en_route = true }, "cancel")
    if not ok then return nil, err end
    FsVisitModel:find(visit.id):update({
        status = "cancelled",
        cancelled_reason = nilify(data.reason) or db.NULL,
    })
    Common.log_activity(namespace_id, visit.job_id, actor_uuid, "visit_cancelled",
        "Visit cancelled" .. (nilify(data.reason) and (": " .. tostring(data.reason)) or ""),
        { visit_uuid = visit.uuid })
    return VisitQueries.getVisit(namespace_id, uuid)
end

return VisitQueries
