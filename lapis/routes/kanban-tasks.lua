--[[
    Kanban Tasks API Routes
    =======================

    RESTful API for task management with assignment and chat integration.

    Task Endpoints:
    - GET    /api/v2/kanban/boards/:board_uuid/tasks          - List tasks for board
    - POST   /api/v2/kanban/boards/:board_uuid/tasks          - Create task
    - GET    /api/v2/kanban/tasks/:uuid                       - Get task details
    - PUT    /api/v2/kanban/tasks/:uuid                       - Update task
    - DELETE /api/v2/kanban/tasks/:uuid                       - Archive task
    - PUT    /api/v2/kanban/tasks/:uuid/move                  - Move task to column

    Assignment Endpoints:
    - GET    /api/v2/kanban/tasks/:uuid/assignees             - Get assignees
    - POST   /api/v2/kanban/tasks/:uuid/assignees             - Assign user (creates chat)
    - DELETE /api/v2/kanban/tasks/:uuid/assignees/:user_uuid  - Unassign user

    Label Endpoints:
    - GET    /api/v2/kanban/tasks/:uuid/labels                - Get labels
    - POST   /api/v2/kanban/tasks/:uuid/labels                - Add label
    - DELETE /api/v2/kanban/tasks/:uuid/labels/:label_id      - Remove label

    Comment Endpoints:
    - GET    /api/v2/kanban/tasks/:uuid/comments              - Get comments
    - POST   /api/v2/kanban/tasks/:uuid/comments              - Add comment
    - PUT    /api/v2/kanban/comments/:uuid                    - Update comment
    - DELETE /api/v2/kanban/comments/:uuid                    - Delete comment

    Checklist Endpoints:
    - GET    /api/v2/kanban/tasks/:uuid/checklists            - Get checklists
    - POST   /api/v2/kanban/tasks/:uuid/checklists            - Create checklist
    - DELETE /api/v2/kanban/checklists/:uuid                  - Delete checklist
    - POST   /api/v2/kanban/checklists/:uuid/items            - Add item
    - PUT    /api/v2/kanban/checklist-items/:uuid/toggle      - Toggle item
    - DELETE /api/v2/kanban/checklist-items/:uuid             - Delete item

    Activity Endpoints:
    - GET    /api/v2/kanban/tasks/:uuid/activities            - Get activity log

    Attachment Endpoints:
    - GET    /api/v2/kanban/tasks/:uuid/attachments           - Get attachments
    - POST   /api/v2/kanban/tasks/:uuid/attachments           - Add attachment
    - DELETE /api/v2/kanban/attachments/:uuid                 - Delete attachment
]]

local cJson = require("cjson")
local KanbanProjectQueries = require "queries.KanbanProjectQueries"
local KanbanBoardQueries = require "queries.KanbanBoardQueries"
local KanbanTaskQueries = require "queries.KanbanTaskQueries"
local Global = require "helper.global"
local db = require("lapis.db")

return function(app)
    ----------------- Helper Functions --------------------

    -- Parse request body (supports both JSON and form-urlencoded)
    local function parse_request_body()
        ngx.req.read_body()

        -- First, check if we have form params (from application/x-www-form-urlencoded)
        local post_args = ngx.req.get_post_args()
        if post_args and next(post_args) then
            return post_args
        end

        -- Fallback to JSON parsing
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

    -- Alias for backward compatibility
    local function parse_json_body()
        return parse_request_body()
    end

    -- Get current user from ngx.ctx (set by auth middleware)
    local function get_current_user()
        local user = ngx.ctx.user
        if not user or not user.uuid then
            return nil, "Unauthorized: Missing user context"
        end
        return user
    end

    -- Get namespace_id from header (supports both UUID and numeric ID)
    local function get_namespace_id()
        local namespace_header = ngx.var.http_x_namespace_id
        if namespace_header and namespace_header ~= "" then
            -- Try as numeric ID first
            local numeric_id = tonumber(namespace_header)
            if numeric_id then
                return numeric_id
            end

            -- Otherwise treat as UUID and look up the namespace
            local result = db.query("SELECT id FROM namespaces WHERE uuid = ? LIMIT 1", namespace_header)
            if result and #result > 0 then
                return result[1].id
            end
        end

        -- Try to get namespace from user context (set by auth middleware)
        local user = ngx.ctx.user
        if user and user.namespace and user.namespace.id then
            return user.namespace.id
        end

        -- Fallback to system namespace
        local result = db.query("SELECT id FROM namespaces WHERE slug = 'system' LIMIT 1")
        if result and #result > 0 then
            return result[1].id
        end

        return nil
    end

    local function api_response(status, data, error_msg)
        if error_msg then
            return {
                status = status,
                json = {
                    success = false,
                    error = error_msg
                }
            }
        end
        return {
            status = status,
            json = {
                success = true,
                data = data
            }
        }
    end

    local function validate_required(data, fields)
        local missing = {}
        for _, field in ipairs(fields) do
            if not data[field] or data[field] == "" then
                table.insert(missing, field)
            end
        end
        if #missing > 0 then
            return false, "Missing required fields: " .. table.concat(missing, ", ")
        end
        return true
    end

    ----------------- Task CRUD Routes --------------------

    -- GET /api/v2/kanban/boards/:board_uuid/tasks - List tasks for board
    app:get("/api/v2/kanban/boards/:board_uuid/tasks", function(self)
        local user, err = get_current_user()
        if not user then
            return api_response(401, nil, err)
        end

        local board = KanbanBoardQueries.show(self.params.board_uuid)
        if not board then
            return api_response(404, nil, "Board not found")
        end

        -- Check membership via project
        if not KanbanProjectQueries.isMember(board.project_id, user.uuid) then
            return api_response(403, nil, "Access denied")
        end

        local params = {
            page = tonumber(self.params.page) or 1,
            perPage = tonumber(self.params.perPage) or 50,
            column_id = self.params.column_id and tonumber(self.params.column_id),
            status = self.params.status,
            priority = self.params.priority,
            assignee_uuid = self.params.assignee_uuid,
            search = self.params.search or self.params.q,
            include_subtasks = self.params.include_subtasks == "true"
        }

        local result = KanbanTaskQueries.getByBoard(board.id, params)

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
    end)

    -- POST /api/v2/kanban/boards/:board_uuid/tasks - Create task
    app:post("/api/v2/kanban/boards/:board_uuid/tasks", function(self)
        local user, err = get_current_user()
        if not user then
            return api_response(401, nil, err)
        end

        local board = KanbanBoardQueries.show(self.params.board_uuid)
        if not board then
            return api_response(404, nil, "Board not found")
        end

        -- Check membership via project
        if not KanbanProjectQueries.isMember(board.project_id, user.uuid) then
            return api_response(403, nil, "Access denied")
        end

        local data = parse_json_body()

        local valid, validation_err = validate_required(data, { "title" })
        if not valid then
            return api_response(400, nil, validation_err)
        end

        -- Validate priority if provided
        if data.priority then
            local valid_priorities = { critical = true, high = true, medium = true, low = true, none = true }
            if not valid_priorities[data.priority] then
                return api_response(400, nil, "Invalid priority. Must be: critical, high, medium, low, or none")
            end
        end

        -- Get first column if not specified
        local column_id = data.column_id
        if not column_id and board.columns and #board.columns > 0 then
            column_id = board.columns[1].id
        end

        local task = KanbanTaskQueries.create({
            board_id = board.id,
            column_id = column_id,
            parent_task_id = data.parent_task_id,
            title = data.title,
            description = data.description,
            status = data.status or "open",
            priority = data.priority or "medium",
            position = data.position,
            story_points = data.story_points,
            time_estimate_minutes = data.time_estimate_minutes,
            start_date = data.start_date,
            due_date = data.due_date,
            reporter_user_uuid = user.uuid,
            cover_image_url = data.cover_image_url,
            cover_color = data.cover_color,
            metadata = data.metadata and cJson.encode(data.metadata) or "{}"
        })

        if not task then
            return api_response(500, nil, "Failed to create task")
        end

        -- Log activity
        KanbanTaskQueries.logActivity(task.id, user.uuid, "created", "task", task.id)

        ngx.log(ngx.INFO, "[Kanban] Task created: ", task.uuid, " #", task.task_number, " by user: ", user.uuid)

        return api_response(201, task)
    end)

    -- GET /api/v2/kanban/tasks/:uuid - Get task details
    app:get("/api/v2/kanban/tasks/:uuid", function(self)
        local user, err = get_current_user()
        if not user then
            return api_response(401, nil, err)
        end

        local task = KanbanTaskQueries.show(self.params.uuid)
        if not task then
            return api_response(404, nil, "Task not found")
        end

        -- Check membership via project
        local board = KanbanBoardQueries.getById(task.board_id)
        if not board or not KanbanProjectQueries.isMember(board.project_id, user.uuid) then
            return api_response(403, nil, "Access denied")
        end

        -- Get additional details
        task.comments = KanbanTaskQueries.getComments(task.id, { perPage = 50 }).data
        task.attachments = KanbanTaskQueries.getAttachments(task.id)

        return api_response(200, task)
    end)

    -- PUT /api/v2/kanban/tasks/:uuid - Update task
    app:put("/api/v2/kanban/tasks/:uuid", function(self)
        local user, err = get_current_user()
        if not user then
            return api_response(401, nil, err)
        end

        local task = KanbanTaskQueries.show(self.params.uuid)
        if not task then
            return api_response(404, nil, "Task not found")
        end

        -- Check membership via project
        local board = KanbanBoardQueries.getById(task.board_id)
        if not board or not KanbanProjectQueries.isMember(board.project_id, user.uuid) then
            return api_response(403, nil, "Access denied")
        end

        local data = parse_json_body()

        local update_params = {}
        local allowed_fields = {
            "title", "description", "status", "priority", "story_points",
            "time_estimate_minutes", "time_spent_minutes", "start_date",
            "due_date", "cover_image_url", "cover_color", "metadata"
        }

        for _, field in ipairs(allowed_fields) do
            if data[field] ~= nil then
                if field == "metadata" then
                    update_params[field] = type(data[field]) == "table" and cJson.encode(data[field]) or data[field]
                else
                    update_params[field] = data[field]
                end
            end
        end

        if next(update_params) == nil then
            return api_response(400, nil, "No valid fields to update")
        end

        -- Validate priority if provided
        if update_params.priority then
            local valid_priorities = { critical = true, high = true, medium = true, low = true, none = true }
            if not valid_priorities[update_params.priority] then
                return api_response(400, nil, "Invalid priority")
            end
        end

        -- Validate status if provided
        if update_params.status then
            local valid_statuses = { open = true, in_progress = true, blocked = true, review = true, completed = true, cancelled = true }
            if not valid_statuses[update_params.status] then
                return api_response(400, nil, "Invalid status")
            end
        end

        local updated = KanbanTaskQueries.update(self.params.uuid, update_params, user.uuid)

        if not updated then
            return api_response(500, nil, "Failed to update task")
        end

        return api_response(200, updated)
    end)

    -- DELETE /api/v2/kanban/tasks/:uuid - Archive task
    app:delete("/api/v2/kanban/tasks/:uuid", function(self)
        local user, err = get_current_user()
        if not user then
            return api_response(401, nil, err)
        end

        local task = KanbanTaskQueries.show(self.params.uuid)
        if not task then
            return api_response(404, nil, "Task not found")
        end

        -- Check membership via project
        local board = KanbanBoardQueries.getById(task.board_id)
        if not board or not KanbanProjectQueries.isMember(board.project_id, user.uuid) then
            return api_response(403, nil, "Access denied")
        end

        local archived = KanbanTaskQueries.archive(self.params.uuid)

        if not archived then
            return api_response(500, nil, "Failed to archive task")
        end

        -- Log activity
        KanbanTaskQueries.logActivity(task.id, user.uuid, "archived", "task", task.id)

        return api_response(200, { message = "Task archived successfully" })
    end)

    -- PUT /api/v2/kanban/tasks/:uuid/move - Move task to different column
    app:put("/api/v2/kanban/tasks/:uuid/move", function(self)
        local user, err = get_current_user()
        if not user then
            return api_response(401, nil, err)
        end

        local task = KanbanTaskQueries.show(self.params.uuid)
        if not task then
            return api_response(404, nil, "Task not found")
        end

        -- Check membership via project
        local board = KanbanBoardQueries.getById(task.board_id)
        if not board or not KanbanProjectQueries.isMember(board.project_id, user.uuid) then
            return api_response(403, nil, "Access denied")
        end

        local data = parse_json_body()

        if not data.column_id then
            return api_response(400, nil, "column_id is required")
        end

        local moved, move_err = KanbanTaskQueries.moveToColumn(
            self.params.uuid,
            data.column_id,
            data.position,
            user.uuid
        )

        if not moved then
            return api_response(400, nil, move_err or "Failed to move task")
        end

        return api_response(200, moved)
    end)

    ----------------- Assignment Routes --------------------

    -- GET /api/v2/kanban/tasks/:uuid/assignees - Get assignees
    app:get("/api/v2/kanban/tasks/:uuid/assignees", function(self)
        local user, err = get_current_user()
        if not user then
            return api_response(401, nil, err)
        end

        local task = KanbanTaskQueries.show(self.params.uuid)
        if not task then
            return api_response(404, nil, "Task not found")
        end

        local assignees = KanbanTaskQueries.getAssignees(task.id)

        return api_response(200, assignees)
    end)

    -- POST /api/v2/kanban/tasks/:uuid/assignees - Assign user (with chat channel creation)
    app:post("/api/v2/kanban/tasks/:uuid/assignees", function(self)
        local user, err = get_current_user()
        if not user then
            return api_response(401, nil, err)
        end

        local namespace_id = get_namespace_id()
        if not namespace_id then
            return api_response(400, nil, "Namespace context required")
        end

        local task = KanbanTaskQueries.show(self.params.uuid)
        if not task then
            return api_response(404, nil, "Task not found")
        end

        -- Check membership via project
        local board = KanbanBoardQueries.getById(task.board_id)
        if not board or not KanbanProjectQueries.isMember(board.project_id, user.uuid) then
            return api_response(403, nil, "Access denied")
        end

        local data = parse_json_body()

        if not data.user_uuid then
            return api_response(400, nil, "user_uuid is required")
        end

        local result, assign_err = KanbanTaskQueries.assignUser(
            task.id,
            data.user_uuid,
            user.uuid,
            namespace_id
        )

        if not result then
            return api_response(400, nil, assign_err or "Failed to assign user")
        end

        ngx.log(ngx.INFO, "[Kanban] User assigned to task: ", task.uuid, " user: ", data.user_uuid, " chat: ", result.chat_channel_uuid)

        return api_response(201, result)
    end)

    -- DELETE /api/v2/kanban/tasks/:uuid/assignees/:user_uuid - Unassign user
    app:delete("/api/v2/kanban/tasks/:uuid/assignees/:user_uuid", function(self)
        local user, err = get_current_user()
        if not user then
            return api_response(401, nil, err)
        end

        local task = KanbanTaskQueries.show(self.params.uuid)
        if not task then
            return api_response(404, nil, "Task not found")
        end

        -- Check membership via project
        local board = KanbanBoardQueries.getById(task.board_id)
        if not board or not KanbanProjectQueries.isMember(board.project_id, user.uuid) then
            return api_response(403, nil, "Access denied")
        end

        local success, unassign_err = KanbanTaskQueries.unassignUser(
            task.id,
            self.params.user_uuid,
            user.uuid
        )

        if not success then
            return api_response(400, nil, unassign_err or "Failed to unassign user")
        end

        return api_response(200, { message = "User unassigned successfully" })
    end)

    ----------------- Label Routes --------------------

    -- GET /api/v2/kanban/tasks/:uuid/labels - Get labels
    app:get("/api/v2/kanban/tasks/:uuid/labels", function(self)
        local user, err = get_current_user()
        if not user then
            return api_response(401, nil, err)
        end

        local task = KanbanTaskQueries.show(self.params.uuid)
        if not task then
            return api_response(404, nil, "Task not found")
        end

        local labels = KanbanTaskQueries.getLabels(task.id)

        return api_response(200, labels)
    end)

    -- POST /api/v2/kanban/tasks/:uuid/labels - Add label
    app:post("/api/v2/kanban/tasks/:uuid/labels", function(self)
        local user, err = get_current_user()
        if not user then
            return api_response(401, nil, err)
        end

        local task = KanbanTaskQueries.show(self.params.uuid)
        if not task then
            return api_response(404, nil, "Task not found")
        end

        local board = KanbanBoardQueries.getById(task.board_id)
        if not board or not KanbanProjectQueries.isMember(board.project_id, user.uuid) then
            return api_response(403, nil, "Access denied")
        end

        local data = parse_json_body()

        if not data.label_id then
            return api_response(400, nil, "label_id is required")
        end

        local link, add_err = KanbanTaskQueries.addLabel(task.id, data.label_id)

        if not link then
            return api_response(400, nil, add_err or "Failed to add label")
        end

        return api_response(201, link)
    end)

    -- DELETE /api/v2/kanban/tasks/:uuid/labels/:label_id - Remove label
    app:delete("/api/v2/kanban/tasks/:uuid/labels/:label_id", function(self)
        local user, err = get_current_user()
        if not user then
            return api_response(401, nil, err)
        end

        local task = KanbanTaskQueries.show(self.params.uuid)
        if not task then
            return api_response(404, nil, "Task not found")
        end

        local board = KanbanBoardQueries.getById(task.board_id)
        if not board or not KanbanProjectQueries.isMember(board.project_id, user.uuid) then
            return api_response(403, nil, "Access denied")
        end

        local success = KanbanTaskQueries.removeLabel(task.id, tonumber(self.params.label_id))

        if not success then
            return api_response(400, nil, "Failed to remove label")
        end

        return api_response(200, { message = "Label removed" })
    end)

    ----------------- Comment Routes --------------------

    -- GET /api/v2/kanban/tasks/:uuid/comments - Get comments
    app:get("/api/v2/kanban/tasks/:uuid/comments", function(self)
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

        local result = KanbanTaskQueries.getComments(task.id, params)

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

    -- POST /api/v2/kanban/tasks/:uuid/comments - Add comment
    app:post("/api/v2/kanban/tasks/:uuid/comments", function(self)
        local user, err = get_current_user()
        if not user then
            return api_response(401, nil, err)
        end

        local task = KanbanTaskQueries.show(self.params.uuid)
        if not task then
            return api_response(404, nil, "Task not found")
        end

        local board = KanbanBoardQueries.getById(task.board_id)
        if not board or not KanbanProjectQueries.isMember(board.project_id, user.uuid) then
            return api_response(403, nil, "Access denied")
        end

        local data = parse_json_body()

        if not data.content or data.content == "" then
            return api_response(400, nil, "content is required")
        end

        local comment = KanbanTaskQueries.addComment({
            task_id = task.id,
            parent_comment_id = data.parent_comment_id,
            user_uuid = user.uuid,
            content = data.content
        })

        if not comment then
            return api_response(500, nil, "Failed to add comment")
        end

        return api_response(201, comment)
    end)

    -- PUT /api/v2/kanban/comments/:uuid - Update comment
    app:put("/api/v2/kanban/comments/:uuid", function(self)
        local user, err = get_current_user()
        if not user then
            return api_response(401, nil, err)
        end

        local data = parse_json_body()

        if not data.content or data.content == "" then
            return api_response(400, nil, "content is required")
        end

        -- Get comment and verify ownership
        local comment_result = db.query([[
            SELECT c.*, t.board_id
            FROM kanban_task_comments c
            INNER JOIN kanban_tasks t ON t.id = c.task_id
            WHERE c.uuid = ?
        ]], self.params.uuid)

        if not comment_result or #comment_result == 0 then
            return api_response(404, nil, "Comment not found")
        end

        local comment_data = comment_result[1]

        if comment_data.user_uuid ~= user.uuid then
            return api_response(403, nil, "You can only edit your own comments")
        end

        local updated = KanbanTaskQueries.updateComment(self.params.uuid, data.content)

        if not updated then
            return api_response(500, nil, "Failed to update comment")
        end

        return api_response(200, updated)
    end)

    -- DELETE /api/v2/kanban/comments/:uuid - Delete comment
    app:delete("/api/v2/kanban/comments/:uuid", function(self)
        local user, err = get_current_user()
        if not user then
            return api_response(401, nil, err)
        end

        -- Get comment and verify ownership
        local comment_result = db.query([[
            SELECT c.*, t.board_id
            FROM kanban_task_comments c
            INNER JOIN kanban_tasks t ON t.id = c.task_id
            WHERE c.uuid = ?
        ]], self.params.uuid)

        if not comment_result or #comment_result == 0 then
            return api_response(404, nil, "Comment not found")
        end

        local comment_data = comment_result[1]

        -- Allow owner or project admin to delete
        local board = KanbanBoardQueries.getById(comment_data.board_id)
        if comment_data.user_uuid ~= user.uuid and not KanbanProjectQueries.isAdmin(board.project_id, user.uuid) then
            return api_response(403, nil, "Permission denied")
        end

        local success = KanbanTaskQueries.deleteComment(self.params.uuid)

        if not success then
            return api_response(500, nil, "Failed to delete comment")
        end

        return api_response(200, { message = "Comment deleted" })
    end)

    ----------------- Checklist Routes --------------------

    -- GET /api/v2/kanban/tasks/:uuid/checklists - Get checklists
    app:get("/api/v2/kanban/tasks/:uuid/checklists", function(self)
        local user, err = get_current_user()
        if not user then
            return api_response(401, nil, err)
        end

        local task = KanbanTaskQueries.show(self.params.uuid)
        if not task then
            return api_response(404, nil, "Task not found")
        end

        local checklists = KanbanTaskQueries.getChecklists(task.id)

        return api_response(200, checklists)
    end)

    -- POST /api/v2/kanban/tasks/:uuid/checklists - Create checklist
    app:post("/api/v2/kanban/tasks/:uuid/checklists", function(self)
        local user, err = get_current_user()
        if not user then
            return api_response(401, nil, err)
        end

        local task = KanbanTaskQueries.show(self.params.uuid)
        if not task then
            return api_response(404, nil, "Task not found")
        end

        local board = KanbanBoardQueries.getById(task.board_id)
        if not board or not KanbanProjectQueries.isMember(board.project_id, user.uuid) then
            return api_response(403, nil, "Access denied")
        end

        local data = parse_json_body()

        if not data.name or data.name == "" then
            return api_response(400, nil, "name is required")
        end

        local checklist = KanbanTaskQueries.createChecklist({
            task_id = task.id,
            name = data.name,
            position = data.position
        })

        if not checklist then
            return api_response(500, nil, "Failed to create checklist")
        end

        return api_response(201, checklist)
    end)

    -- DELETE /api/v2/kanban/checklists/:uuid - Delete checklist
    app:delete("/api/v2/kanban/checklists/:uuid", function(self)
        local user, err = get_current_user()
        if not user then
            return api_response(401, nil, err)
        end

        local success = KanbanTaskQueries.deleteChecklist(self.params.uuid)

        if not success then
            return api_response(404, nil, "Checklist not found")
        end

        return api_response(200, { message = "Checklist deleted" })
    end)

    -- POST /api/v2/kanban/checklists/:uuid/items - Add checklist item
    app:post("/api/v2/kanban/checklists/:uuid/items", function(self)
        local user, err = get_current_user()
        if not user then
            return api_response(401, nil, err)
        end

        local data = parse_json_body()

        if not data.content or data.content == "" then
            return api_response(400, nil, "content is required")
        end

        -- Get checklist
        local checklist = db.query("SELECT * FROM kanban_task_checklists WHERE uuid = ?", self.params.uuid)
        if not checklist or #checklist == 0 then
            return api_response(404, nil, "Checklist not found")
        end

        local item = KanbanTaskQueries.addChecklistItem({
            checklist_id = checklist[1].id,
            content = data.content,
            assignee_user_uuid = data.assignee_user_uuid,
            due_date = data.due_date,
            position = data.position
        })

        if not item then
            return api_response(500, nil, "Failed to add item")
        end

        return api_response(201, item)
    end)

    -- PUT /api/v2/kanban/checklist-items/:uuid/toggle - Toggle checklist item
    app:put("/api/v2/kanban/checklist-items/:uuid/toggle", function(self)
        local user, err = get_current_user()
        if not user then
            return api_response(401, nil, err)
        end

        local item = KanbanTaskQueries.toggleChecklistItem(self.params.uuid, user.uuid)

        if not item then
            return api_response(404, nil, "Item not found")
        end

        return api_response(200, item)
    end)

    -- DELETE /api/v2/kanban/checklist-items/:uuid - Delete checklist item
    app:delete("/api/v2/kanban/checklist-items/:uuid", function(self)
        local user, err = get_current_user()
        if not user then
            return api_response(401, nil, err)
        end

        local success = KanbanTaskQueries.deleteChecklistItem(self.params.uuid)

        if not success then
            return api_response(404, nil, "Item not found")
        end

        return api_response(200, { message = "Item deleted" })
    end)

    ----------------- Activity Routes --------------------

    -- GET /api/v2/kanban/tasks/:uuid/activities - Get activity log
    app:get("/api/v2/kanban/tasks/:uuid/activities", function(self)
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

        local result = KanbanTaskQueries.getActivities(task.id, params)

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

    ----------------- Attachment Routes --------------------

    -- GET /api/v2/kanban/tasks/:uuid/attachments - Get attachments
    app:get("/api/v2/kanban/tasks/:uuid/attachments", function(self)
        local user, err = get_current_user()
        if not user then
            return api_response(401, nil, err)
        end

        local task = KanbanTaskQueries.show(self.params.uuid)
        if not task then
            return api_response(404, nil, "Task not found")
        end

        local attachments = KanbanTaskQueries.getAttachments(task.id)

        return api_response(200, attachments)
    end)

    -- POST /api/v2/kanban/tasks/:uuid/attachments - Add attachment
    app:post("/api/v2/kanban/tasks/:uuid/attachments", function(self)
        local user, err = get_current_user()
        if not user then
            return api_response(401, nil, err)
        end

        local task = KanbanTaskQueries.show(self.params.uuid)
        if not task then
            return api_response(404, nil, "Task not found")
        end

        local board = KanbanBoardQueries.getById(task.board_id)
        if not board or not KanbanProjectQueries.isMember(board.project_id, user.uuid) then
            return api_response(403, nil, "Access denied")
        end

        local data = parse_json_body()

        local valid, validation_err = validate_required(data, { "file_name", "file_url" })
        if not valid then
            return api_response(400, nil, validation_err)
        end

        local attachment = KanbanTaskQueries.addAttachment({
            task_id = task.id,
            uploaded_by = user.uuid,
            file_name = data.file_name,
            file_url = data.file_url,
            file_type = data.file_type,
            file_size = data.file_size,
            thumbnail_url = data.thumbnail_url
        })

        if not attachment then
            return api_response(500, nil, "Failed to add attachment")
        end

        return api_response(201, attachment)
    end)

    -- DELETE /api/v2/kanban/attachments/:uuid - Delete attachment
    app:delete("/api/v2/kanban/attachments/:uuid", function(self)
        local user, err = get_current_user()
        if not user then
            return api_response(401, nil, err)
        end

        -- Get attachment and verify permission
        local attachment_result = db.query([[
            SELECT a.*, t.board_id
            FROM kanban_task_attachments a
            INNER JOIN kanban_tasks t ON t.id = a.task_id
            WHERE a.uuid = ?
        ]], self.params.uuid)

        if not attachment_result or #attachment_result == 0 then
            return api_response(404, nil, "Attachment not found")
        end

        local attachment_data = attachment_result[1]

        -- Allow uploader or project admin
        local board = KanbanBoardQueries.getById(attachment_data.board_id)
        if attachment_data.uploaded_by ~= user.uuid and not KanbanProjectQueries.isAdmin(board.project_id, user.uuid) then
            return api_response(403, nil, "Permission denied")
        end

        local success = KanbanTaskQueries.deleteAttachment(self.params.uuid)

        if not success then
            return api_response(500, nil, "Failed to delete attachment")
        end

        return api_response(200, { message = "Attachment deleted" })
    end)
end
