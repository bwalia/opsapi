--[[
    Kanban Labels API Routes
    ========================

    RESTful API for project-level label management.

    Endpoints:
    - GET    /api/v2/kanban/projects/:project_uuid/labels     - List labels
    - POST   /api/v2/kanban/projects/:project_uuid/labels     - Create label
    - PUT    /api/v2/kanban/labels/:uuid                      - Update label
    - DELETE /api/v2/kanban/labels/:uuid                      - Delete label
]]

local cJson = require("cjson")
local KanbanProjectQueries = require "queries.KanbanProjectQueries"
local KanbanTaskLabelModel = require "models.KanbanTaskLabelModel"
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

    ----------------- Label Routes --------------------

    -- GET /api/v2/kanban/projects/:project_uuid/labels - List labels for project
    app:get("/api/v2/kanban/projects/:project_uuid/labels", function(self)
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

        local labels = db.query([[
            SELECT l.*,
                   (SELECT COUNT(*) FROM kanban_task_label_links WHERE label_id = l.id) as task_count
            FROM kanban_task_labels l
            WHERE l.project_id = ?
            ORDER BY l.name ASC
        ]], project.id)

        return api_response(200, labels)
    end)

    -- POST /api/v2/kanban/projects/:project_uuid/labels - Create label
    app:post("/api/v2/kanban/projects/:project_uuid/labels", function(self)
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
            return api_response(403, nil, "Only project admins can create labels")
        end

        local data = parse_json_body()

        if not data.name or data.name == "" then
            return api_response(400, nil, "name is required")
        end

        -- Check for duplicate name
        local existing = db.query([[
            SELECT id FROM kanban_task_labels WHERE project_id = ? AND name = ?
        ]], project.id, data.name)

        if existing and #existing > 0 then
            return api_response(400, nil, "A label with this name already exists")
        end

        local label = KanbanTaskLabelModel:create({
            uuid = Global.generateUUID(),
            project_id = project.id,
            name = data.name,
            color = data.color or "#6B7280",
            description = data.description,
            created_at = db.raw("NOW()"),
            updated_at = db.raw("NOW()")
        }, { returning = "*" })

        if not label then
            return api_response(500, nil, "Failed to create label")
        end

        return api_response(201, label)
    end)

    -- PUT /api/v2/kanban/labels/:uuid - Update label
    app:put("/api/v2/kanban/labels/:uuid", function(self)
        local user, err = get_current_user()
        if not user then
            return api_response(401, nil, err)
        end

        local label = KanbanTaskLabelModel:find({ uuid = self.params.uuid })
        if not label then
            return api_response(404, nil, "Label not found")
        end

        -- Check admin access via project
        if not KanbanProjectQueries.isAdmin(label.project_id, user.uuid) then
            return api_response(403, nil, "Only project admins can update labels")
        end

        local data = parse_json_body()

        local update_params = {}
        if data.name then update_params.name = data.name end
        if data.color then update_params.color = data.color end
        if data.description ~= nil then update_params.description = data.description end

        if next(update_params) == nil then
            return api_response(400, nil, "No valid fields to update")
        end

        -- Check for duplicate name if changing name
        if update_params.name and update_params.name ~= label.name then
            local existing = db.query([[
                SELECT id FROM kanban_task_labels WHERE project_id = ? AND name = ? AND id != ?
            ]], label.project_id, update_params.name, label.id)

            if existing and #existing > 0 then
                return api_response(400, nil, "A label with this name already exists")
            end
        end

        update_params.updated_at = db.raw("NOW()")

        local updated = label:update(update_params, { returning = "*" })

        if not updated then
            return api_response(500, nil, "Failed to update label")
        end

        return api_response(200, updated)
    end)

    -- DELETE /api/v2/kanban/labels/:uuid - Delete label
    app:delete("/api/v2/kanban/labels/:uuid", function(self)
        local user, err = get_current_user()
        if not user then
            return api_response(401, nil, err)
        end

        local label = KanbanTaskLabelModel:find({ uuid = self.params.uuid })
        if not label then
            return api_response(404, nil, "Label not found")
        end

        -- Check admin access via project
        if not KanbanProjectQueries.isAdmin(label.project_id, user.uuid) then
            return api_response(403, nil, "Only project admins can delete labels")
        end

        label:delete()

        return api_response(200, { message = "Label deleted successfully" })
    end)
end
