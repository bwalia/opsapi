--[[
    Kanban Epics API Routes
    =======================

    RESTful API for epics: a project-level container that groups tasks and
    reports rollup progress (story points + task counts).

    Epic CRUD:
    - GET    /api/v2/kanban/projects/:project_uuid/epics   - List epics (with rollups)
    - POST   /api/v2/kanban/projects/:project_uuid/epics   - Create epic
    - GET    /api/v2/kanban/epics/:uuid                    - Get epic details
    - PUT    /api/v2/kanban/epics/:uuid                    - Update epic
    - DELETE /api/v2/kanban/epics/:uuid                    - Delete epic (soft)

    Epic Tasks:
    - GET    /api/v2/kanban/epics/:uuid/tasks              - Tasks in the epic
    - POST   /api/v2/kanban/epics/:uuid/tasks              - Attach task(s)
    - DELETE /api/v2/kanban/epics/:uuid/tasks              - Detach task(s)

    Tenancy: every handler runs behind requireAuth + requireNamespace, and the
    project/epic lookups are re-scoped to self.namespace.id explicitly -- the
    middleware resolves the tenant, it does not filter SQL.
]]

local cJson = require("cjson")
local KanbanEpicQueries = require "queries.KanbanEpicQueries"
local KanbanProjectQueries = require "queries.KanbanProjectQueries"
local AuthMiddleware = require("middleware.auth")
local NamespaceMiddleware = require("middleware.namespace")

return function(app)
    ----------------- Helper Functions --------------------

    --- Read the request body as a table.
    -- Tries JSON first whenever the body looks like JSON. The older kanban
    -- routes try ngx.req.get_post_args() first, which mis-parses a JSON body
    -- into a single bogus key (`{"name":"x"}` becomes the KEY) instead of
    -- falling through to the decoder -- so those endpoints only accept
    -- form-encoded bodies. Ordering the checks by content-type accepts both.
    local function parse_request_body()
        ngx.req.read_body()

        local body = ngx.req.get_body_data()
        local content_type = ngx.var.content_type or ""
        local looks_like_json = body and body:match("^%s*[{%[]")

        if body and body ~= "" and (content_type:find("application/json", 1, true) or looks_like_json) then
            local ok, decoded = pcall(cJson.decode, body)
            if ok and type(decoded) == "table" then
                return decoded
            end
        end

        local post_args = ngx.req.get_post_args()
        if post_args and next(post_args) then
            return post_args
        end

        return {}
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

    --- Resolve the project named in the URL, scoped to the caller's namespace.
    -- A project in another tenant reads as "not found", never as 403.
    -- @return table|nil { project, namespace_id, user }, or nil + an error response
    local function resolve_project(self)
        local user = self.current_user
        local namespace_id = self.namespace and self.namespace.id
        if not namespace_id then
            return nil, api_response(400, nil, "Namespace required")
        end

        local project = KanbanProjectQueries.show(self.params.project_uuid, user.uuid, namespace_id)
        if not project then
            return nil, api_response(404, nil, "Project not found")
        end

        return { project = project, namespace_id = namespace_id, user = user }
    end

    --- Resolve the epic named in the URL, scoped to the caller's namespace.
    -- @return table|nil { epic, namespace_id, user }, or nil + an error response
    local function resolve_epic(self)
        local user = self.current_user
        local namespace_id = self.namespace and self.namespace.id
        if not namespace_id then
            return nil, api_response(400, nil, "Namespace required")
        end

        local epic = KanbanEpicQueries.show(self.params.uuid, namespace_id)
        if not epic then
            return nil, api_response(404, nil, "Epic not found")
        end

        return { epic = epic, namespace_id = namespace_id, user = user }
    end

    --- Accept task_uuids as an array, or as a JSON-encoded string (which is
    --- what a form-encoded body delivers).
    local function parse_task_uuids(data)
        local list = data.task_uuids or data.task_ids
        if type(list) == "string" and list ~= "" then
            local ok, decoded = pcall(cJson.decode, list)
            list = ok and decoded or nil
        end
        if type(list) ~= "table" or #list == 0 then
            return nil
        end
        return list
    end

    ----------------- Epic CRUD Routes --------------------

    -- GET /api/v2/kanban/projects/:project_uuid/epics - List epics
    app:get("/api/v2/kanban/projects/:project_uuid/epics", AuthMiddleware.requireAuth(
        NamespaceMiddleware.requireNamespace(function(self)
            local ctx, err_response = resolve_project(self)
            if not ctx then return err_response end
            local project, namespace_id, user = ctx.project, ctx.namespace_id, ctx.user

            if not KanbanProjectQueries.isMember(project.id, user.uuid) then
                return api_response(403, nil, "Access denied")
            end

            local params = {
                page = tonumber(self.params.page) or 1,
                perPage = tonumber(self.params.perPage) or tonumber(self.params.per_page) or 20,
                status = self.params.status
            }

            local result = KanbanEpicQueries.getByProject(project.id, namespace_id, params)

            return {
                status = 200,
                json = {
                    success = true,
                    data = result.data,
                    meta = {
                        total = result.total,
                        page = params.page,
                        perPage = params.perPage,
                        totalPages = math.ceil(result.total / params.perPage)
                    }
                }
            }
        end)))

    -- POST /api/v2/kanban/projects/:project_uuid/epics - Create epic
    app:post("/api/v2/kanban/projects/:project_uuid/epics", AuthMiddleware.requireAuth(
        NamespaceMiddleware.requireNamespace(function(self)
            local ctx, err_response = resolve_project(self)
            if not ctx then return err_response end
            local project, namespace_id, user = ctx.project, ctx.namespace_id, ctx.user

            if not KanbanProjectQueries.isAdmin(project.id, user.uuid) then
                return api_response(403, nil, "Only project admins can create epics")
            end

            local data = parse_request_body()

            if not data.name or data.name == "" then
                return api_response(400, nil, "name is required")
            end

            local epic, create_err = KanbanEpicQueries.create({
                project_id = project.id,
                namespace_id = namespace_id,
                name = data.name,
                description = data.description,
                status = data.status,
                color = data.color,
                start_date = data.start_date,
                due_date = data.due_date,
                created_by = user.uuid
            })

            if not epic then
                return api_response(400, nil, create_err or "Failed to create epic")
            end

            ngx.log(ngx.INFO, "[Epic] Created: ", epic.uuid, " in project: ", project.uuid)

            return api_response(201, KanbanEpicQueries.show(epic.uuid, namespace_id) or epic)
        end)))

    -- GET /api/v2/kanban/epics/:uuid - Get epic details
    app:get("/api/v2/kanban/epics/:uuid", AuthMiddleware.requireAuth(
        NamespaceMiddleware.requireNamespace(function(self)
            local ctx, err_response = resolve_epic(self)
            if not ctx then return err_response end
            local epic, user = ctx.epic, ctx.user

            if not KanbanProjectQueries.isMember(epic.project_id, user.uuid) then
                return api_response(403, nil, "Access denied")
            end

            return api_response(200, epic)
        end)))

    -- PUT /api/v2/kanban/epics/:uuid - Update epic
    app:put("/api/v2/kanban/epics/:uuid", AuthMiddleware.requireAuth(
        NamespaceMiddleware.requireNamespace(function(self)
            local ctx, err_response = resolve_epic(self)
            if not ctx then return err_response end
            local epic, namespace_id, user = ctx.epic, ctx.namespace_id, ctx.user

            if not KanbanProjectQueries.isAdmin(epic.project_id, user.uuid) then
                return api_response(403, nil, "Only project admins can update epics")
            end

            local data = parse_request_body()

            local update_params = {}
            local allowed_fields = {
                "name", "description", "status", "color", "start_date", "due_date"
            }

            for _, field in ipairs(allowed_fields) do
                if data[field] ~= nil then
                    update_params[field] = data[field]
                end
            end

            if next(update_params) == nil then
                return api_response(400, nil, "No valid fields to update")
            end

            local updated, update_err = KanbanEpicQueries.update(epic.uuid, namespace_id, update_params)

            if not updated then
                return api_response(400, nil, update_err or "Failed to update epic")
            end

            return api_response(200, updated)
        end)))

    -- DELETE /api/v2/kanban/epics/:uuid - Delete epic (soft)
    app:delete("/api/v2/kanban/epics/:uuid", AuthMiddleware.requireAuth(
        NamespaceMiddleware.requireNamespace(function(self)
            local ctx, err_response = resolve_epic(self)
            if not ctx then return err_response end
            local epic, namespace_id, user = ctx.epic, ctx.namespace_id, ctx.user

            if not KanbanProjectQueries.isAdmin(epic.project_id, user.uuid) then
                return api_response(403, nil, "Only project admins can delete epics")
            end

            local success, delete_err = KanbanEpicQueries.destroy(epic.uuid, namespace_id)

            if not success then
                return api_response(400, nil, delete_err or "Failed to delete epic")
            end

            return api_response(200, { message = "Epic deleted" })
        end)))

    ----------------- Epic Task Routes --------------------

    -- GET /api/v2/kanban/epics/:uuid/tasks - Tasks in the epic
    app:get("/api/v2/kanban/epics/:uuid/tasks", AuthMiddleware.requireAuth(
        NamespaceMiddleware.requireNamespace(function(self)
            local ctx, err_response = resolve_epic(self)
            if not ctx then return err_response end
            local epic, user = ctx.epic, ctx.user

            if not KanbanProjectQueries.isMember(epic.project_id, user.uuid) then
                return api_response(403, nil, "Access denied")
            end

            local params = {
                page = tonumber(self.params.page) or 1,
                perPage = tonumber(self.params.perPage) or tonumber(self.params.per_page) or 50
            }

            local result = KanbanEpicQueries.getTasks(epic.id, params)

            return {
                status = 200,
                json = {
                    success = true,
                    data = result.data,
                    meta = {
                        total = result.total,
                        page = params.page,
                        perPage = params.perPage,
                        totalPages = math.ceil(result.total / params.perPage)
                    }
                }
            }
        end)))

    -- POST /api/v2/kanban/epics/:uuid/tasks - Attach task(s) to the epic
    app:post("/api/v2/kanban/epics/:uuid/tasks", AuthMiddleware.requireAuth(
        NamespaceMiddleware.requireNamespace(function(self)
            local ctx, err_response = resolve_epic(self)
            if not ctx then return err_response end
            local epic, user = ctx.epic, ctx.user

            if not KanbanProjectQueries.isEditor(epic.project_id, user.uuid) then
                return api_response(403, nil, "Read-only access: this action requires an editor role")
            end

            local task_uuids = parse_task_uuids(parse_request_body())
            if not task_uuids then
                return api_response(400, nil, "task_uuids array is required")
            end

            local count = KanbanEpicQueries.assignTasks(epic, task_uuids)

            return api_response(200, {
                message = "Tasks attached to epic",
                attached_count = count
            })
        end)))

    -- DELETE /api/v2/kanban/epics/:uuid/tasks - Detach task(s) from the epic
    app:delete("/api/v2/kanban/epics/:uuid/tasks", AuthMiddleware.requireAuth(
        NamespaceMiddleware.requireNamespace(function(self)
            local ctx, err_response = resolve_epic(self)
            if not ctx then return err_response end
            local epic, user = ctx.epic, ctx.user

            if not KanbanProjectQueries.isEditor(epic.project_id, user.uuid) then
                return api_response(403, nil, "Read-only access: this action requires an editor role")
            end

            local task_uuids = parse_task_uuids(parse_request_body())
            if not task_uuids then
                return api_response(400, nil, "task_uuids array is required")
            end

            local count = KanbanEpicQueries.unassignTasks(epic, task_uuids)

            return api_response(200, {
                message = "Tasks detached from epic",
                detached_count = count
            })
        end)))
end
