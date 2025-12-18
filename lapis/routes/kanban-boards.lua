--[[
    Kanban Boards API Routes
    ========================

    RESTful API for board and column management within projects.

    Endpoints:
    - GET    /api/v2/kanban/projects/:project_uuid/boards            - List boards
    - POST   /api/v2/kanban/projects/:project_uuid/boards            - Create board
    - GET    /api/v2/kanban/boards/:uuid                             - Get board details
    - GET    /api/v2/kanban/boards/:uuid/full                        - Get board with all tasks
    - PUT    /api/v2/kanban/boards/:uuid                             - Update board
    - DELETE /api/v2/kanban/boards/:uuid                             - Archive board
    - PUT    /api/v2/kanban/boards/:uuid/reorder                     - Reorder boards
    - GET    /api/v2/kanban/boards/:uuid/stats                       - Get board statistics

    Column Endpoints:
    - POST   /api/v2/kanban/boards/:uuid/columns                     - Create column
    - PUT    /api/v2/kanban/columns/:uuid                            - Update column
    - DELETE /api/v2/kanban/columns/:uuid                            - Delete column
    - PUT    /api/v2/kanban/boards/:uuid/columns/reorder             - Reorder columns
]]

local cJson = require("cjson")
local KanbanProjectQueries = require "queries.KanbanProjectQueries"
local KanbanBoardQueries = require "queries.KanbanBoardQueries"
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

    ----------------- Board Routes --------------------

    -- GET /api/v2/kanban/projects/:project_uuid/boards - List boards for project
    app:get("/api/v2/kanban/projects/:project_uuid/boards", function(self)
        local user, err = get_current_user()
        if not user then
            return api_response(401, nil, err)
        end

        local project = KanbanProjectQueries.show(self.params.project_uuid)
        if not project then
            return api_response(404, nil, "Project not found")
        end

        -- Check membership
        if not KanbanProjectQueries.isMember(project.id, user.uuid) then
            return api_response(403, nil, "Access denied")
        end

        local include_archived = self.params.include_archived == "true"
        local boards = KanbanBoardQueries.getByProject(project.id, include_archived)

        return api_response(200, boards)
    end)

    -- POST /api/v2/kanban/projects/:project_uuid/boards - Create board
    app:post("/api/v2/kanban/projects/:project_uuid/boards", function(self)
        local user, err = get_current_user()
        if not user then
            return api_response(401, nil, err)
        end

        local project = KanbanProjectQueries.show(self.params.project_uuid)
        if not project then
            return api_response(404, nil, "Project not found")
        end

        -- Check admin access
        if not KanbanProjectQueries.isAdmin(project.id, user.uuid) then
            return api_response(403, nil, "Only project admins can create boards")
        end

        local data = parse_json_body()

        local valid, validation_err = validate_required(data, { "name" })
        if not valid then
            return api_response(400, nil, validation_err)
        end

        local board = KanbanBoardQueries.create({
            project_id = project.id,
            name = data.name,
            description = data.description,
            position = data.position,
            wip_limit = data.wip_limit,
            settings = data.settings and cJson.encode(data.settings) or "{}",
            created_by = user.uuid,
            create_default_columns = data.create_default_columns ~= false
        })

        if not board then
            return api_response(500, nil, "Failed to create board")
        end

        ngx.log(ngx.INFO, "[Kanban] Board created: ", board.uuid, " in project: ", project.uuid)

        return api_response(201, board)
    end)

    -- GET /api/v2/kanban/boards/:uuid - Get board details
    app:get("/api/v2/kanban/boards/:uuid", function(self)
        local user, err = get_current_user()
        if not user then
            return api_response(401, nil, err)
        end

        local board = KanbanBoardQueries.show(self.params.uuid)
        if not board then
            return api_response(404, nil, "Board not found")
        end

        -- Check membership via project
        if not KanbanProjectQueries.isMember(board.project_id, user.uuid) then
            return api_response(403, nil, "Access denied")
        end

        return api_response(200, board)
    end)

    -- GET /api/v2/kanban/boards/:uuid/full - Get board with all tasks (full board view)
    app:get("/api/v2/kanban/boards/:uuid/full", function(self)
        local user, err = get_current_user()
        if not user then
            return api_response(401, nil, err)
        end

        local board = KanbanBoardQueries.getFullBoard(self.params.uuid)
        if not board then
            return api_response(404, nil, "Board not found")
        end

        -- Check membership via project
        if not KanbanProjectQueries.isMember(board.project_id, user.uuid) then
            return api_response(403, nil, "Access denied")
        end

        return api_response(200, board)
    end)

    -- PUT /api/v2/kanban/boards/:uuid - Update board
    app:put("/api/v2/kanban/boards/:uuid", function(self)
        local user, err = get_current_user()
        if not user then
            return api_response(401, nil, err)
        end

        local board = KanbanBoardQueries.show(self.params.uuid)
        if not board then
            return api_response(404, nil, "Board not found")
        end

        -- Check admin access via project
        if not KanbanProjectQueries.isAdmin(board.project_id, user.uuid) then
            return api_response(403, nil, "Only project admins can update boards")
        end

        local data = parse_json_body()

        local update_params = {}
        local allowed_fields = { "name", "description", "wip_limit", "settings" }

        for _, field in ipairs(allowed_fields) do
            if data[field] ~= nil then
                if field == "settings" then
                    update_params[field] = type(data[field]) == "table" and cJson.encode(data[field]) or data[field]
                else
                    update_params[field] = data[field]
                end
            end
        end

        if next(update_params) == nil then
            return api_response(400, nil, "No valid fields to update")
        end

        local updated = KanbanBoardQueries.update(self.params.uuid, update_params)

        if not updated then
            return api_response(500, nil, "Failed to update board")
        end

        return api_response(200, updated)
    end)

    -- DELETE /api/v2/kanban/boards/:uuid - Archive board
    app:delete("/api/v2/kanban/boards/:uuid", function(self)
        local user, err = get_current_user()
        if not user then
            return api_response(401, nil, err)
        end

        local board = KanbanBoardQueries.show(self.params.uuid)
        if not board then
            return api_response(404, nil, "Board not found")
        end

        -- Check admin access via project
        if not KanbanProjectQueries.isAdmin(board.project_id, user.uuid) then
            return api_response(403, nil, "Only project admins can archive boards")
        end

        -- Can't archive default board
        if board.is_default then
            return api_response(400, nil, "Cannot archive the default board")
        end

        local archived = KanbanBoardQueries.archive(self.params.uuid)

        if not archived then
            return api_response(500, nil, "Failed to archive board")
        end

        return api_response(200, { message = "Board archived successfully" })
    end)

    -- PUT /api/v2/kanban/boards/:uuid/reorder - Reorder boards in project
    app:put("/api/v2/kanban/boards/:uuid/reorder", function(self)
        local user, err = get_current_user()
        if not user then
            return api_response(401, nil, err)
        end

        local board = KanbanBoardQueries.show(self.params.uuid)
        if not board then
            return api_response(404, nil, "Board not found")
        end

        -- Check admin access via project
        if not KanbanProjectQueries.isAdmin(board.project_id, user.uuid) then
            return api_response(403, nil, "Only project admins can reorder boards")
        end

        local data = parse_json_body()

        if not data.positions or type(data.positions) ~= "table" then
            return api_response(400, nil, "positions array is required")
        end

        KanbanBoardQueries.reorder(board.project_id, data.positions)

        return api_response(200, { message = "Boards reordered successfully" })
    end)

    -- GET /api/v2/kanban/boards/:uuid/stats - Get board statistics
    app:get("/api/v2/kanban/boards/:uuid/stats", function(self)
        local user, err = get_current_user()
        if not user then
            return api_response(401, nil, err)
        end

        local board = KanbanBoardQueries.show(self.params.uuid)
        if not board then
            return api_response(404, nil, "Board not found")
        end

        -- Check membership via project
        if not KanbanProjectQueries.isMember(board.project_id, user.uuid) then
            return api_response(403, nil, "Access denied")
        end

        local stats = KanbanBoardQueries.getStats(board.id)

        return api_response(200, stats)
    end)

    ----------------- Column Routes --------------------

    -- POST /api/v2/kanban/boards/:uuid/columns - Create column
    app:post("/api/v2/kanban/boards/:uuid/columns", function(self)
        local user, err = get_current_user()
        if not user then
            return api_response(401, nil, err)
        end

        local board = KanbanBoardQueries.show(self.params.uuid)
        if not board then
            return api_response(404, nil, "Board not found")
        end

        -- Check admin access via project
        if not KanbanProjectQueries.isAdmin(board.project_id, user.uuid) then
            return api_response(403, nil, "Only project admins can create columns")
        end

        local data = parse_json_body()

        local valid, validation_err = validate_required(data, { "name" })
        if not valid then
            return api_response(400, nil, validation_err)
        end

        local column = KanbanBoardQueries.createColumn({
            board_id = board.id,
            name = data.name,
            description = data.description,
            position = data.position,
            color = data.color,
            wip_limit = data.wip_limit,
            is_done_column = data.is_done_column or false,
            auto_close_tasks = data.auto_close_tasks or false
        })

        if not column then
            return api_response(500, nil, "Failed to create column")
        end

        return api_response(201, column)
    end)

    -- PUT /api/v2/kanban/columns/:uuid - Update column
    app:put("/api/v2/kanban/columns/:uuid", function(self)
        local user, err = get_current_user()
        if not user then
            return api_response(401, nil, err)
        end

        local column = KanbanBoardQueries.getColumn(self.params.uuid)
        if not column then
            return api_response(404, nil, "Column not found")
        end

        -- Check admin access via project
        if not KanbanProjectQueries.isAdmin(column.project_id, user.uuid) then
            return api_response(403, nil, "Only project admins can update columns")
        end

        local data = parse_json_body()

        local update_params = {}
        local allowed_fields = { "name", "description", "color", "wip_limit", "is_done_column", "auto_close_tasks" }

        for _, field in ipairs(allowed_fields) do
            if data[field] ~= nil then
                update_params[field] = data[field]
            end
        end

        if next(update_params) == nil then
            return api_response(400, nil, "No valid fields to update")
        end

        local updated = KanbanBoardQueries.updateColumn(self.params.uuid, update_params)

        if not updated then
            return api_response(500, nil, "Failed to update column")
        end

        return api_response(200, updated)
    end)

    -- DELETE /api/v2/kanban/columns/:uuid - Delete column
    app:delete("/api/v2/kanban/columns/:uuid", function(self)
        local user, err = get_current_user()
        if not user then
            return api_response(401, nil, err)
        end

        local column = KanbanBoardQueries.getColumn(self.params.uuid)
        if not column then
            return api_response(404, nil, "Column not found")
        end

        -- Check admin access via project
        if not KanbanProjectQueries.isAdmin(column.project_id, user.uuid) then
            return api_response(403, nil, "Only project admins can delete columns")
        end

        -- Ensure at least one column remains
        local columns_count = db.query([[
            SELECT COUNT(*) as count FROM kanban_columns WHERE board_id = ?
        ]], column.board_id)

        if columns_count and tonumber(columns_count[1].count) <= 1 then
            return api_response(400, nil, "Cannot delete the last column in a board")
        end

        local deleted = KanbanBoardQueries.deleteColumn(self.params.uuid)

        if not deleted then
            return api_response(500, nil, "Failed to delete column")
        end

        return api_response(200, { message = "Column deleted successfully" })
    end)

    -- PUT /api/v2/kanban/boards/:uuid/columns/reorder - Reorder columns
    app:put("/api/v2/kanban/boards/:uuid/columns/reorder", function(self)
        local user, err = get_current_user()
        if not user then
            return api_response(401, nil, err)
        end

        local board = KanbanBoardQueries.show(self.params.uuid)
        if not board then
            return api_response(404, nil, "Board not found")
        end

        -- Check admin access via project
        if not KanbanProjectQueries.isAdmin(board.project_id, user.uuid) then
            return api_response(403, nil, "Only project admins can reorder columns")
        end

        local data = parse_json_body()

        if not data.positions or type(data.positions) ~= "table" then
            return api_response(400, nil, "positions array is required")
        end

        KanbanBoardQueries.reorderColumns(board.id, data.positions)

        return api_response(200, { message = "Columns reordered successfully" })
    end)
end
