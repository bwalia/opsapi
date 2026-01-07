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

        local task = KanbanTaskQueries.show(data.task_uuid)
        if not task then
            return api_response(404, nil, "Task not found")
        end

        local entry, start_err = KanbanTimeTrackingQueries.startTimer(
            task.id,
            user.uuid,
            data.description
        )

        if not entry then
            return api_response(400, nil, start_err or "Failed to start timer")
        end

        ngx.log(ngx.INFO, "[TimeTracking] Timer started by user: ", user.uuid)

        return api_response(201, entry)
    end)

    -- POST /api/v2/kanban/timer/stop - Stop running timer
    app:post("/api/v2/kanban/timer/stop", function(self)
        local user, err = get_current_user()
        if not user then
            return api_response(401, nil, err)
        end

        local data = parse_request_body()

        local entry, stop_err = KanbanTimeTrackingQueries.stopTimer(
            user.uuid,
            data.description
        )

        if not entry then
            return api_response(400, nil, stop_err or "Failed to stop timer")
        end

        ngx.log(ngx.INFO, "[TimeTracking] Timer stopped by user: ", user.uuid, " duration: ", entry.duration_minutes, " min")

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

        local task = KanbanTaskQueries.show(self.params.uuid)
        if not task then
            return api_response(404, nil, "Task not found")
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

    -- POST /api/v2/kanban/tasks/:uuid/time-entries - Create manual time entry
    app:post("/api/v2/kanban/tasks/:uuid/time-entries", function(self)
        local user, err = get_current_user()
        if not user then
            return api_response(401, nil, err)
        end

        local task = KanbanTaskQueries.show(self.params.uuid)
        if not task then
            return api_response(404, nil, "Task not found")
        end

        local data = parse_request_body()

        -- Validate required fields
        if not data.duration_minutes and (not data.started_at or not data.ended_at) then
            return api_response(400, nil, "Either duration_minutes or started_at/ended_at is required")
        end

        local entry, create_err = KanbanTimeTrackingQueries.create({
            task_id = task.id,
            user_uuid = user.uuid,
            description = data.description,
            started_at = data.started_at or db.raw("NOW()"),
            ended_at = data.ended_at,
            duration_minutes = data.duration_minutes,
            is_billable = data.is_billable ~= false,
            hourly_rate = data.hourly_rate
        })

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

        -- TODO: Add permission check for approver role

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
