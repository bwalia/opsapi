--[[
    Kanban Time Tracking API Routes
    ================================

    RESTful API for time tracking and timesheet management.

    Timer Endpoints:
    - POST   /api/v2/kanban/timer/start              - Start a timer
    - POST   /api/v2/kanban/timer/stop               - Stop running timer
    - GET    /api/v2/kanban/timer/current            - Get current running timer

    Time Entry Endpoints:
    - GET    /api/v2/kanban/tasks/:uuid/time-entries - Get time entries for task
    - POST   /api/v2/kanban/tasks/:uuid/time-entries - Create manual time entry
    - GET    /api/v2/kanban/time-entries/:uuid       - Get time entry details
    - PUT    /api/v2/kanban/time-entries/:uuid       - Update time entry
    - DELETE /api/v2/kanban/time-entries/:uuid       - Delete time entry
    - PUT    /api/v2/kanban/time-entries/:uuid/approve - Approve time entry
    - PUT    /api/v2/kanban/time-entries/:uuid/reject  - Reject time entry

    Timesheet Endpoints:
    - GET    /api/v2/kanban/timesheet                - Get user's timesheet
    - GET    /api/v2/kanban/projects/:uuid/time-report - Get project time report
]]

local cJson = require("cjson")
local KanbanTimeTrackingQueries = require "queries.KanbanTimeTrackingQueries"
local KanbanTaskQueries = require "queries.KanbanTaskQueries"
local KanbanProjectQueries = require "queries.KanbanProjectQueries"
local db = require("lapis.db")

return function(app)
    ----------------- Helper Functions --------------------

    local function parse_request_body()
        ngx.req.read_body()

        -- Try to get body data (could be nil if body is in a temp file)
        local body = ngx.req.get_body_data()

        -- If body is in a temp file, read from there
        if not body then
            local body_file = ngx.req.get_body_file()
            if body_file then
                local f = io.open(body_file, "r")
                if f then
                    body = f:read("*all")
                    f:close()
                end
            end
        end

        -- Check content type to determine parsing method
        local content_type = ngx.var.content_type or ""

        -- If JSON content type, parse as JSON first
        if content_type:find("application/json", 1, true) then
            if body and body ~= "" then
                local ok, result = pcall(cJson.decode, body)
                if ok and type(result) == "table" then
                    return result
                end
            end
            return {}
        end

        -- For form data, try get_post_args
        local post_args = ngx.req.get_post_args()
        if post_args and next(post_args) then
            return post_args
        end

        -- Fallback: try to parse as JSON anyway
        if body and body ~= "" then
            local ok, result = pcall(cJson.decode, body)
            if ok and type(result) == "table" then
                return result
            end
        end

        return {}
    end

    local function get_current_user()
        local user = ngx.ctx.user
        if not user or not user.uuid then
            return nil, "Unauthorized: Missing user context"
        end
        return user
    end

    local function get_namespace_id()
        local namespace_header = ngx.var.http_x_namespace_id
        if namespace_header and namespace_header ~= "" then
            local numeric_id = tonumber(namespace_header)
            if numeric_id then
                return numeric_id
            end
            local result = db.query("SELECT id FROM namespaces WHERE uuid = ? LIMIT 1", namespace_header)
            if result and #result > 0 then
                return result[1].id
            end
        end

        local user = ngx.ctx.user
        if user and user.namespace and user.namespace.id then
            return user.namespace.id
        end

        return nil
    end

    local function api_response(status, data, error_msg)
        if error_msg then
            return {
                status = status,
                json = { success = false, error = error_msg }
            }
        end
        return {
            status = status,
            json = { success = true, data = data }
        }
    end

    -- Tenant-isolation + authorization helpers.
    -- kanban_time_entries has no namespace_id column, so the tenant boundary is
    -- enforced transitively: a user may only act on a task / time entry whose
    -- owning project they are a member of. Project membership rows are
    -- namespace-bound, so this both authorizes the user AND prevents cross-tenant
    -- access (IDOR) without trusting any client-supplied namespace header.

    -- Resolve a task by uuid and assert the caller is a member of its project.
    -- @return task, project_id  OR  nil, nil, error_message
    local function authorize_task(task_uuid, user_uuid)
        local task = KanbanTaskQueries.show(task_uuid)
        if not task then return nil, nil, "Task not found" end
        local ctx = db.query([[
            SELECT b.project_id AS project_id
            FROM kanban_tasks t
            JOIN kanban_boards b ON b.id = t.board_id
            WHERE t.uuid = ? LIMIT 1
        ]], task_uuid)
        local project_id = ctx and ctx[1] and ctx[1].project_id
        if not project_id then return nil, nil, "Task not found" end
        if not KanbanProjectQueries.isMember(project_id, user_uuid) then
            -- Do not reveal existence across tenants: respond as not-found.
            return nil, nil, "Task not found"
        end
        return task, project_id
    end

    -- Resolve a time entry by uuid and assert the caller is a member of its
    -- project. @return entry_ctx {id, uuid, user_uuid, project_id} OR nil, nil, err
    local function authorize_entry(entry_uuid, user_uuid)
        local ctx = db.query([[
            SELECT te.id, te.uuid, te.user_uuid, b.project_id AS project_id
            FROM kanban_time_entries te
            JOIN kanban_tasks t ON t.id = te.task_id
            JOIN kanban_boards b ON b.id = t.board_id
            WHERE te.uuid = ? AND te.deleted_at IS NULL
            LIMIT 1
        ]], entry_uuid)
        if not ctx or not ctx[1] then return nil, nil, "Time entry not found" end
        local row = ctx[1]
        if not KanbanProjectQueries.isMember(row.project_id, user_uuid) then
            return nil, nil, "Time entry not found"
        end
        return row, row.project_id
    end

    ----------------- Timer Routes --------------------

    -- POST /api/v2/kanban/timer/start - Start a timer
    app:post("/api/v2/kanban/timer/start", function(self)
        local user, err = get_current_user()
        if not user then
            return api_response(401, nil, err)
        end

        local data = parse_request_body()

        if not data.task_uuid then
            return api_response(400, nil, "task_uuid is required")
        end

        local task, _, auth_err = authorize_task(data.task_uuid, user.uuid)
        if not task then
            return api_response(404, nil, auth_err or "Task not found")
        end

        ngx.log(ngx.INFO, "[TimeTracking] Starting timer - task_uuid: ", data.task_uuid, " task.id: ", task.id, " user.uuid: ", user.uuid)

        -- Debug: Check what entries exist for this task
        local debug_entries = db.query([[
            SELECT id, task_id, user_uuid, status, duration_minutes,
                   TO_CHAR(started_at, 'YYYY-MM-DD HH24:MI:SS') as started_at,
                   TO_CHAR(ended_at, 'YYYY-MM-DD HH24:MI:SS') as ended_at
            FROM kanban_time_entries
            WHERE task_id = ? AND user_uuid = ? AND deleted_at IS NULL
            ORDER BY id DESC LIMIT 5
        ]], task.id, user.uuid)
        ngx.log(ngx.INFO, "[TimeTracking] Debug - found ", #(debug_entries or {}), " entries for task_id=", task.id)
        for i, e in ipairs(debug_entries or {}) do
            ngx.log(ngx.INFO, "[TimeTracking] Entry ", i, ": id=", e.id, " status=", e.status, " duration_minutes=", (e.duration_minutes or "nil"), " started=", e.started_at, " ended=", (e.ended_at or "nil"))
        end

        -- Get previous seconds for this task BEFORE starting (for accurate resume)
        local previous_seconds = KanbanTimeTrackingQueries.getTaskTotalSeconds(task.id, user.uuid)
        ngx.log(ngx.INFO, "[TimeTracking] Got previous_seconds: ", previous_seconds)

        local entry, start_err = KanbanTimeTrackingQueries.startTimer(
            task.id,
            user.uuid,
            data.description
        )

        if not entry then
            return api_response(400, nil, start_err or "Failed to start timer")
        end

        ngx.log(ngx.INFO, "[TimeTracking] Timer started by user: ", user.uuid, " previous_seconds: ", previous_seconds)

        -- Include previous_seconds in response for accurate timer display
        return api_response(201, {
            uuid = entry.uuid,
            task_id = entry.task_id,
            user_uuid = entry.user_uuid,
            started_at = entry.started_at,
            previous_seconds = previous_seconds
        })
    end)

    -- POST /api/v2/kanban/timer/stop - Stop running timer
    -- Accepts: description (optional), accumulated_seconds (optional, client-tracked time)
    app:post("/api/v2/kanban/timer/stop", function(self)
        local user, err = get_current_user()
        if not user then
            return api_response(401, nil, err)
        end

        local data = parse_request_body()

        ngx.log(ngx.INFO, "[TimeTracking] Stop request - raw data: ", require("cjson").encode(data))

        -- Get accumulated_seconds from client (more accurate than server calculation).
        -- Sanitize: the client value is untrusted and feeds billed time, so reject
        -- NaN/inf/negative and cap at a sane per-session ceiling (24h) to prevent
        -- absurd durations corrupting the billing/timesheet pipeline.
        local accumulated_seconds = nil
        if data.accumulated_seconds then
            local n = tonumber(data.accumulated_seconds)
            if n and n == n and n ~= math.huge and n ~= -math.huge and n > 0 then
                local MAX_SESSION_SECONDS = 24 * 60 * 60
                if n > MAX_SESSION_SECONDS then n = MAX_SESSION_SECONDS end
                accumulated_seconds = n
            end
            ngx.log(ngx.INFO, "[TimeTracking] Received accumulated_seconds from client: ", tostring(accumulated_seconds))
        else
            ngx.log(ngx.INFO, "[TimeTracking] No accumulated_seconds in request")
        end

        local entry, stop_err = KanbanTimeTrackingQueries.stopTimer(
            user.uuid,
            data.description,
            accumulated_seconds
        )

        if not entry then
            ngx.log(ngx.ERR, "[TimeTracking] Stop timer failed: ", stop_err)
            return api_response(400, nil, stop_err or "Failed to stop timer")
        end

        ngx.log(ngx.INFO, "[TimeTracking] Timer stopped by user: ", user.uuid, " entry.task_id: ", entry.task_id, " duration_minutes: ", entry.duration_minutes, " duration_seconds: ", (entry.duration_seconds or "nil"))

        return api_response(200, entry)
    end)

    -- GET /api/v2/kanban/timer/current - Get current running timer
    app:get("/api/v2/kanban/timer/current", function(self)
        local user, err = get_current_user()
        if not user then
            return api_response(401, nil, err)
        end

        local timer = KanbanTimeTrackingQueries.getRunningTimer(user.uuid)

        if timer then
            -- Create a new table with running flag to ensure it serializes properly
            -- Total seconds = previous completed sessions + current session elapsed
            local total_seconds = (timer.previous_seconds or 0) + (timer.elapsed_seconds or 0)
            local response = {
                running = true,
                uuid = timer.uuid,
                task_id = timer.task_id,
                task_uuid = timer.task_uuid,
                task_title = timer.task_title,
                task_number = timer.task_number,
                board_name = timer.board_name,
                project_name = timer.project_name,
                project_uuid = timer.project_uuid,
                started_at = timer.started_at,
                elapsed_seconds = timer.elapsed_seconds,
                previous_seconds = timer.previous_seconds,
                total_seconds = total_seconds,
                description = timer.description,
                user_uuid = timer.user_uuid
            }
            return api_response(200, response)
        else
            return api_response(200, { running = false })
        end
    end)

    ----------------- Time Entry Routes --------------------

    -- GET /api/v2/kanban/tasks/:uuid/time-entries - Get time entries for task
    app:get("/api/v2/kanban/tasks/:uuid/time-entries", function(self)
        local user, err = get_current_user()
        if not user then
            return api_response(401, nil, err)
        end

        local task, _, auth_err = authorize_task(self.params.uuid, user.uuid)
        if not task then
            return api_response(404, nil, auth_err or "Task not found")
        end

        local params = {
            page = tonumber(self.params.page) or 1,
            perPage = tonumber(self.params.perPage) or 20
        }

        local result = KanbanTimeTrackingQueries.getByTask(task.id, params)

        return {
            status = 200,
            json = {
                success = true,
                data = result.data,
                meta = {
                    total = result.total,
                    page = params.page,
                    perPage = params.perPage
                }
            }
        }
    end)

    -- GET /api/v2/kanban/tasks/:uuid/time-summary - Combined time spent on a task
    -- (kanban board time + Timesheets module time), with a per-contributor breakdown.
    app:get("/api/v2/kanban/tasks/:uuid/time-summary", function(self)
        local user, err = get_current_user()
        if not user then
            return api_response(401, nil, err)
        end

        local task, _, auth_err = authorize_task(self.params.uuid, user.uuid)
        if not task then
            return api_response(404, nil, auth_err or "Task not found")
        end

        local summary = KanbanTimeTrackingQueries.getTaskTimeSummary(task.id, task.uuid)

        return api_response(200, summary)
    end)

    -- POST /api/v2/kanban/tasks/:uuid/time-entries - Create manual time entry
    app:post("/api/v2/kanban/tasks/:uuid/time-entries", function(self)
        local user, err = get_current_user()
        if not user then
            return api_response(401, nil, err)
        end

        local task, _, auth_err = authorize_task(self.params.uuid, user.uuid)
        if not task then
            return api_response(404, nil, auth_err or "Task not found")
        end

        local data = parse_request_body()

        -- Validate required fields
        if not data.duration_minutes and (not data.started_at or not data.ended_at) then
            return api_response(400, nil, "Either duration_minutes or started_at/ended_at is required")
        end

        -- Validate duration is a sane positive number (untrusted, feeds billing).
        if data.duration_minutes ~= nil then
            local mins = tonumber(data.duration_minutes)
            if not mins or mins ~= mins or mins <= 0 or mins > 24 * 60 then
                return api_response(400, nil, "duration_minutes must be between 0 and 1440")
            end
        end

        -- Wrap create: malformed started_at/ended_at timestamps hit a Postgres cast
        -- and would otherwise surface as a raw 500 instead of a clean 400.
        local ok, entry, create_err = pcall(KanbanTimeTrackingQueries.create, {
            task_id = task.id,
            user_uuid = user.uuid,
            description = data.description,
            started_at = data.started_at or db.raw("NOW()"),
            ended_at = data.ended_at,
            duration_minutes = data.duration_minutes,
            is_billable = data.is_billable ~= false,
            hourly_rate = data.hourly_rate
        })

        if not ok then
            ngx.log(ngx.ERR, "[TimeTracking] manual entry create failed: ", tostring(entry))
            return api_response(400, nil, "Could not create time entry — check started_at/ended_at and duration")
        end
        if not entry then
            return api_response(400, nil, create_err or "Failed to create time entry")
        end

        return api_response(201, entry)
    end)

    -- PUT /api/v2/kanban/time-entries/:uuid - Update time entry
    app:put("/api/v2/kanban/time-entries/:uuid", function(self)
        local user, err = get_current_user()
        if not user then
            return api_response(401, nil, err)
        end

        -- Tenant + membership check: the entry must belong to a project the
        -- caller is a member of. The query additionally enforces self-ownership.
        local _, _, ent_err = authorize_entry(self.params.uuid, user.uuid)
        if ent_err then
            return api_response(404, nil, ent_err)
        end

        local data = parse_request_body()

        local update_params = {}
        local allowed_fields = {
            "description", "started_at", "ended_at", "duration_minutes",
            "is_billable", "hourly_rate"
        }

        for _, field in ipairs(allowed_fields) do
            if data[field] ~= nil then
                update_params[field] = data[field]
            end
        end

        if next(update_params) == nil then
            return api_response(400, nil, "No valid fields to update")
        end

        local updated, update_err = KanbanTimeTrackingQueries.update(
            self.params.uuid,
            update_params,
            user.uuid
        )

        if not updated then
            return api_response(400, nil, update_err or "Failed to update time entry")
        end

        return api_response(200, updated)
    end)

    -- DELETE /api/v2/kanban/time-entries/:uuid - Delete time entry
    app:delete("/api/v2/kanban/time-entries/:uuid", function(self)
        local user, err = get_current_user()
        if not user then
            return api_response(401, nil, err)
        end

        -- Tenant + membership check before deleting (query also enforces ownership).
        local _, _, ent_err = authorize_entry(self.params.uuid, user.uuid)
        if ent_err then
            return api_response(404, nil, ent_err)
        end

        local success, delete_err = KanbanTimeTrackingQueries.delete(
            self.params.uuid,
            user.uuid
        )

        if not success then
            return api_response(400, nil, delete_err or "Failed to delete time entry")
        end

        return api_response(200, { message = "Time entry deleted" })
    end)

    -- PUT /api/v2/kanban/time-entries/:uuid/approve - Approve time entry
    app:put("/api/v2/kanban/time-entries/:uuid/approve", function(self)
        local user, err = get_current_user()
        if not user then
            return api_response(401, nil, err)
        end

        -- Approving billable time is a privileged action: the approver must be a
        -- project admin/owner of the entry's project (which is namespace-bound).
        -- Approvers also cannot approve their own entries.
        local ent, project_id, ent_err = authorize_entry(self.params.uuid, user.uuid)
        if ent_err then
            return api_response(404, nil, ent_err)
        end
        if not KanbanProjectQueries.isAdmin(project_id, user.uuid) then
            return api_response(403, nil, "Only a project admin can approve time entries")
        end
        if ent.user_uuid == user.uuid then
            return api_response(403, nil, "You cannot approve your own time entry")
        end

        local approved, approve_err = KanbanTimeTrackingQueries.approve(
            self.params.uuid,
            user.uuid
        )

        if not approved then
            return api_response(400, nil, approve_err or "Failed to approve time entry")
        end

        return api_response(200, approved)
    end)

    -- PUT /api/v2/kanban/time-entries/:uuid/reject - Reject time entry
    app:put("/api/v2/kanban/time-entries/:uuid/reject", function(self)
        local user, err = get_current_user()
        if not user then
            return api_response(401, nil, err)
        end

        -- Rejecting time is privileged: require project admin/owner (namespace-bound).
        local _, project_id, ent_err = authorize_entry(self.params.uuid, user.uuid)
        if ent_err then
            return api_response(404, nil, ent_err)
        end
        if not KanbanProjectQueries.isAdmin(project_id, user.uuid) then
            return api_response(403, nil, "Only a project admin can reject time entries")
        end

        local rejected, reject_err = KanbanTimeTrackingQueries.reject(
            self.params.uuid,
            user.uuid
        )

        if not rejected then
            return api_response(400, nil, reject_err or "Failed to reject time entry")
        end

        return api_response(200, rejected)
    end)

    ----------------- Timesheet Routes --------------------

    -- GET /api/v2/kanban/timesheet - Get user's timesheet
    app:get("/api/v2/kanban/timesheet", function(self)
        local user, err = get_current_user()
        if not user then
            return api_response(401, nil, err)
        end

        local params = {
            page = tonumber(self.params.page) or 1,
            perPage = tonumber(self.params.perPage) or 50,
            start_date = self.params.start_date,
            end_date = self.params.end_date,
            project_id = self.params.project_id and tonumber(self.params.project_id),
            status = self.params.status
        }

        local result = KanbanTimeTrackingQueries.getByUser(user.uuid, params)

        return {
            status = 200,
            json = {
                success = true,
                data = result.data,
                summary = result.summary,
                meta = {
                    total = result.total,
                    page = params.page,
                    perPage = params.perPage
                }
            }
        }
    end)

    -- GET /api/v2/kanban/projects/:uuid/time-report - Get project time report
    app:get("/api/v2/kanban/projects/:uuid/time-report", function(self)
        local user, err = get_current_user()
        if not user then
            return api_response(401, nil, err)
        end

        local project = KanbanProjectQueries.show(self.params.uuid)
        if not project then
            return api_response(404, nil, "Project not found")
        end

        -- Check membership
        if not KanbanProjectQueries.isMember(project.id, user.uuid) then
            return api_response(403, nil, "Access denied")
        end

        local params = {
            page = tonumber(self.params.page) or 1,
            perPage = tonumber(self.params.perPage) or 50,
            start_date = self.params.start_date,
            end_date = self.params.end_date,
            user_uuid = self.params.user_uuid,
            status = self.params.status
        }

        local result = KanbanTimeTrackingQueries.getByProject(project.id, params)

        -- Get user breakdown if date range provided
        local user_report = nil
        if params.start_date and params.end_date then
            user_report = KanbanTimeTrackingQueries.getUserReport(
                project.id,
                params.start_date,
                params.end_date
            )
        end

        return {
            status = 200,
            json = {
                success = true,
                data = result.data,
                summary = result.summary,
                user_breakdown = user_report,
                meta = {
                    total = result.total,
                    page = params.page,
                    perPage = params.perPage
                }
            }
        }
    end)
end
