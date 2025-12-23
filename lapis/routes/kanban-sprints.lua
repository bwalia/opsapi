--[[
    Kanban Sprints API Routes
    ==========================

    RESTful API for sprint management in agile projects.

    Sprint CRUD:
    - GET    /api/v2/kanban/projects/:project_uuid/sprints       - List sprints
    - POST   /api/v2/kanban/projects/:project_uuid/sprints       - Create sprint
    - GET    /api/v2/kanban/sprints/:uuid                        - Get sprint details
    - PUT    /api/v2/kanban/sprints/:uuid                        - Update sprint
    - DELETE /api/v2/kanban/sprints/:uuid                        - Delete sprint

    Sprint Lifecycle:
    - POST   /api/v2/kanban/sprints/:uuid/start                  - Start sprint
    - POST   /api/v2/kanban/sprints/:uuid/complete               - Complete sprint
    - POST   /api/v2/kanban/sprints/:uuid/cancel                 - Cancel sprint

    Sprint Tasks:
    - GET    /api/v2/kanban/sprints/:uuid/tasks                  - Get sprint tasks
    - POST   /api/v2/kanban/sprints/:uuid/tasks                  - Add tasks to sprint
    - DELETE /api/v2/kanban/sprints/:uuid/tasks                  - Remove tasks from sprint

    Sprint Analytics:
    - GET    /api/v2/kanban/sprints/:uuid/burndown               - Get burndown data
    - GET    /api/v2/kanban/projects/:project_uuid/velocity      - Get velocity history
]]

local cJson = require("cjson")
local KanbanSprintQueries = require "queries.KanbanSprintQueries"
local KanbanProjectQueries = require "queries.KanbanProjectQueries"
local db = require("lapis.db")

return function(app)
    ----------------- Helper Functions --------------------

    local function parse_request_body()
        ngx.req.read_body()
        local post_args = ngx.req.get_post_args()
        if post_args and next(post_args) then
            return post_args
        end

        local ok, result = pcall(function()
            local body = ngx.req.get_body_data()
            if not body or body == "" then
                return {}
            end
            return cJson.decode(body)
        end)

        if ok and type(result) == "table" then
            return result
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

    ----------------- Sprint CRUD Routes --------------------

    -- GET /api/v2/kanban/projects/:project_uuid/sprints - List sprints
    app:get("/api/v2/kanban/projects/:project_uuid/sprints", function(self)
        local user, err = get_current_user()
        if not user then
            return api_response(401, nil, err)
        end

        local project = KanbanProjectQueries.show(self.params.project_uuid)
        if not project then
            return api_response(404, nil, "Project not found")
        end

        if not KanbanProjectQueries.isMember(project.id, user.uuid) then
            return api_response(403, nil, "Access denied")
        end

        local params = {
            page = tonumber(self.params.page) or 1,
            perPage = tonumber(self.params.perPage) or 20,
            status = self.params.status,
            board_id = self.params.board_id and tonumber(self.params.board_id)
        }

        local result = KanbanSprintQueries.getByProject(project.id, params)

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

    -- POST /api/v2/kanban/projects/:project_uuid/sprints - Create sprint
    app:post("/api/v2/kanban/projects/:project_uuid/sprints", function(self)
        local user, err = get_current_user()
        if not user then
            return api_response(401, nil, err)
        end

        local project = KanbanProjectQueries.show(self.params.project_uuid)
        if not project then
            return api_response(404, nil, "Project not found")
        end

        if not KanbanProjectQueries.isAdmin(project.id, user.uuid) then
            return api_response(403, nil, "Only project admins can create sprints")
        end

        local data = parse_request_body()

        if not data.name or data.name == "" then
            return api_response(400, nil, "name is required")
        end

        local sprint, create_err = KanbanSprintQueries.create({
            project_id = project.id,
            board_id = data.board_id,
            name = data.name,
            goal = data.goal,
            start_date = data.start_date,
            end_date = data.end_date
        })

        if not sprint then
            return api_response(400, nil, create_err or "Failed to create sprint")
        end

        ngx.log(ngx.INFO, "[Sprint] Created: ", sprint.uuid, " in project: ", project.uuid)

        return api_response(201, sprint)
    end)

    -- GET /api/v2/kanban/sprints/:uuid - Get sprint details
    app:get("/api/v2/kanban/sprints/:uuid", function(self)
        local user, err = get_current_user()
        if not user then
            return api_response(401, nil, err)
        end

        local sprint = KanbanSprintQueries.show(self.params.uuid)
        if not sprint then
            return api_response(404, nil, "Sprint not found")
        end

        if not KanbanProjectQueries.isMember(sprint.project_id, user.uuid) then
            return api_response(403, nil, "Access denied")
        end

        return api_response(200, sprint)
    end)

    -- PUT /api/v2/kanban/sprints/:uuid - Update sprint
    app:put("/api/v2/kanban/sprints/:uuid", function(self)
        local user, err = get_current_user()
        if not user then
            return api_response(401, nil, err)
        end

        local sprint = KanbanSprintQueries.show(self.params.uuid)
        if not sprint then
            return api_response(404, nil, "Sprint not found")
        end

        if not KanbanProjectQueries.isAdmin(sprint.project_id, user.uuid) then
            return api_response(403, nil, "Only project admins can update sprints")
        end

        local data = parse_request_body()

        local update_params = {}
        local allowed_fields = {
            "name", "goal", "start_date", "end_date", "board_id",
            "retrospective", "review_notes"
        }

        for _, field in ipairs(allowed_fields) do
            if data[field] ~= nil then
                update_params[field] = data[field]
            end
        end

        if next(update_params) == nil then
            return api_response(400, nil, "No valid fields to update")
        end

        local updated, update_err = KanbanSprintQueries.update(self.params.uuid, update_params)

        if not updated then
            return api_response(400, nil, update_err or "Failed to update sprint")
        end

        return api_response(200, updated)
    end)

    -- DELETE /api/v2/kanban/sprints/:uuid - Delete sprint
    app:delete("/api/v2/kanban/sprints/:uuid", function(self)
        local user, err = get_current_user()
        if not user then
            return api_response(401, nil, err)
        end

        local sprint = KanbanSprintQueries.show(self.params.uuid)
        if not sprint then
            return api_response(404, nil, "Sprint not found")
        end

        if not KanbanProjectQueries.isAdmin(sprint.project_id, user.uuid) then
            return api_response(403, nil, "Only project admins can delete sprints")
        end

        local success, delete_err = KanbanSprintQueries.delete(self.params.uuid)

        if not success then
            return api_response(400, nil, delete_err or "Failed to delete sprint")
        end

        return api_response(200, { message = "Sprint deleted" })
    end)

    ----------------- Sprint Lifecycle Routes --------------------

    -- POST /api/v2/kanban/sprints/:uuid/start - Start sprint
    app:post("/api/v2/kanban/sprints/:uuid/start", function(self)
        local user, err = get_current_user()
        if not user then
            return api_response(401, nil, err)
        end

        local sprint = KanbanSprintQueries.show(self.params.uuid)
        if not sprint then
            return api_response(404, nil, "Sprint not found")
        end

        if not KanbanProjectQueries.isAdmin(sprint.project_id, user.uuid) then
            return api_response(403, nil, "Only project admins can start sprints")
        end

        local started, start_err = KanbanSprintQueries.start(self.params.uuid)

        if not started then
            return api_response(400, nil, start_err or "Failed to start sprint")
        end

        ngx.log(ngx.INFO, "[Sprint] Started: ", sprint.uuid, " by user: ", user.uuid)

        return api_response(200, started)
    end)

    -- POST /api/v2/kanban/sprints/:uuid/complete - Complete sprint
    app:post("/api/v2/kanban/sprints/:uuid/complete", function(self)
        local user, err = get_current_user()
        if not user then
            return api_response(401, nil, err)
        end

        local sprint = KanbanSprintQueries.show(self.params.uuid)
        if not sprint then
            return api_response(404, nil, "Sprint not found")
        end

        if not KanbanProjectQueries.isAdmin(sprint.project_id, user.uuid) then
            return api_response(403, nil, "Only project admins can complete sprints")
        end

        local data = parse_request_body()

        local completed, complete_err = KanbanSprintQueries.complete(
            self.params.uuid,
            data.retrospective
        )

        if not completed then
            return api_response(400, nil, complete_err or "Failed to complete sprint")
        end

        ngx.log(ngx.INFO, "[Sprint] Completed: ", sprint.uuid, " velocity: ", completed.velocity)

        return api_response(200, completed)
    end)

    -- POST /api/v2/kanban/sprints/:uuid/cancel - Cancel sprint
    app:post("/api/v2/kanban/sprints/:uuid/cancel", function(self)
        local user, err = get_current_user()
        if not user then
            return api_response(401, nil, err)
        end

        local sprint = KanbanSprintQueries.show(self.params.uuid)
        if not sprint then
            return api_response(404, nil, "Sprint not found")
        end

        if not KanbanProjectQueries.isAdmin(sprint.project_id, user.uuid) then
            return api_response(403, nil, "Only project admins can cancel sprints")
        end

        local cancelled, cancel_err = KanbanSprintQueries.cancel(self.params.uuid)

        if not cancelled then
            return api_response(400, nil, cancel_err or "Failed to cancel sprint")
        end

        return api_response(200, cancelled)
    end)

    ----------------- Sprint Task Routes --------------------

    -- GET /api/v2/kanban/sprints/:uuid/tasks - Get sprint tasks
    app:get("/api/v2/kanban/sprints/:uuid/tasks", function(self)
        local user, err = get_current_user()
        if not user then
            return api_response(401, nil, err)
        end

        local sprint = KanbanSprintQueries.show(self.params.uuid)
        if not sprint then
            return api_response(404, nil, "Sprint not found")
        end

        if not KanbanProjectQueries.isMember(sprint.project_id, user.uuid) then
            return api_response(403, nil, "Access denied")
        end

        local params = {
            page = tonumber(self.params.page) or 1,
            perPage = tonumber(self.params.perPage) or 50
        }

        local result = KanbanSprintQueries.getTasks(sprint.id, params)

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

    -- POST /api/v2/kanban/sprints/:uuid/tasks - Add tasks to sprint
    app:post("/api/v2/kanban/sprints/:uuid/tasks", function(self)
        local user, err = get_current_user()
        if not user then
            return api_response(401, nil, err)
        end

        local sprint = KanbanSprintQueries.show(self.params.uuid)
        if not sprint then
            return api_response(404, nil, "Sprint not found")
        end

        if not KanbanProjectQueries.isMember(sprint.project_id, user.uuid) then
            return api_response(403, nil, "Access denied")
        end

        local data = parse_request_body()

        if not data.task_ids or type(data.task_ids) ~= "table" or #data.task_ids == 0 then
            return api_response(400, nil, "task_ids array is required")
        end

        local count = KanbanSprintQueries.addTasks(sprint.id, data.task_ids)

        return api_response(200, {
            message = "Tasks added to sprint",
            added_count = count
        })
    end)

    -- DELETE /api/v2/kanban/sprints/:uuid/tasks - Remove tasks from sprint
    app:delete("/api/v2/kanban/sprints/:uuid/tasks", function(self)
        local user, err = get_current_user()
        if not user then
            return api_response(401, nil, err)
        end

        local sprint = KanbanSprintQueries.show(self.params.uuid)
        if not sprint then
            return api_response(404, nil, "Sprint not found")
        end

        if not KanbanProjectQueries.isMember(sprint.project_id, user.uuid) then
            return api_response(403, nil, "Access denied")
        end

        local data = parse_request_body()

        if not data.task_ids or type(data.task_ids) ~= "table" or #data.task_ids == 0 then
            return api_response(400, nil, "task_ids array is required")
        end

        local count = KanbanSprintQueries.removeTasks(sprint.id, data.task_ids)

        return api_response(200, {
            message = "Tasks removed from sprint",
            removed_count = count
        })
    end)

    ----------------- Sprint Analytics Routes --------------------

    -- GET /api/v2/kanban/sprints/:uuid/burndown - Get burndown data
    app:get("/api/v2/kanban/sprints/:uuid/burndown", function(self)
        local user, err = get_current_user()
        if not user then
            return api_response(401, nil, err)
        end

        local sprint = KanbanSprintQueries.show(self.params.uuid)
        if not sprint then
            return api_response(404, nil, "Sprint not found")
        end

        if not KanbanProjectQueries.isMember(sprint.project_id, user.uuid) then
            return api_response(403, nil, "Access denied")
        end

        -- Record current day's data if sprint is active
        if sprint.status == "active" then
            KanbanSprintQueries.recordBurndown(sprint.id)
        end

        local burndown = KanbanSprintQueries.getBurndown(sprint.id)

        return api_response(200, {
            sprint = {
                uuid = sprint.uuid,
                name = sprint.name,
                start_date = sprint.start_date,
                end_date = sprint.end_date,
                total_points = sprint.total_points,
                completed_points = sprint.completed_points
            },
            data_points = burndown
        })
    end)

    -- GET /api/v2/kanban/projects/:project_uuid/velocity - Get velocity history
    app:get("/api/v2/kanban/projects/:project_uuid/velocity", function(self)
        local user, err = get_current_user()
        if not user then
            return api_response(401, nil, err)
        end

        local project = KanbanProjectQueries.show(self.params.project_uuid)
        if not project then
            return api_response(404, nil, "Project not found")
        end

        if not KanbanProjectQueries.isMember(project.id, user.uuid) then
            return api_response(403, nil, "Access denied")
        end

        local limit = tonumber(self.params.limit) or 10

        local velocity = KanbanSprintQueries.getVelocityHistory(project.id, limit)

        return api_response(200, velocity)
    end)
end
