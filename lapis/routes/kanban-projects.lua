--[[
    Kanban Projects API Routes
    ==========================

    RESTful API for project management with Kanban boards.
    Projects are namespace-scoped for multi-tenant isolation.

    Endpoints:
    - GET    /api/v2/kanban/projects              - List projects
    - POST   /api/v2/kanban/projects              - Create project
    - GET    /api/v2/kanban/projects/:uuid        - Get project details
    - PUT    /api/v2/kanban/projects/:uuid        - Update project
    - DELETE /api/v2/kanban/projects/:uuid        - Archive project
    - GET    /api/v2/kanban/projects/:uuid/stats  - Get project statistics
    - GET    /api/v2/kanban/projects/:uuid/members - Get project members
    - POST   /api/v2/kanban/projects/:uuid/members - Add member
    - DELETE /api/v2/kanban/projects/:uuid/members/:user_uuid - Remove member
    - PUT    /api/v2/kanban/projects/:uuid/members/:user_uuid/role - Update role
    - POST   /api/v2/kanban/projects/:uuid/star   - Toggle starred
    - GET    /api/v2/kanban/my-tasks              - Get tasks assigned to current user
]]

local cJson = require("cjson")
local KanbanProjectQueries = require "queries.KanbanProjectQueries"
local KanbanBoardQueries = require "queries.KanbanBoardQueries"
local KanbanTaskQueries = require "queries.KanbanTaskQueries"
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

    -- Standard API response wrapper
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

    -- Validate required fields
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

    ----------------- Project Routes --------------------

    -- GET /api/v2/kanban/projects - List projects
    app:get("/api/v2/kanban/projects", function(self)
        local user, err = get_current_user()
        if not user then
            return api_response(401, nil, err)
        end

        local namespace_id = get_namespace_id()
        if not namespace_id then
            return api_response(400, nil, "Namespace context required")
        end

        local params = {
            page = tonumber(self.params.page) or 1,
            perPage = tonumber(self.params.perPage) or 20,
            status = self.params.status,
            search = self.params.search or self.params.q
        }

        -- Get projects user is a member of
        local result = KanbanProjectQueries.getByUser(user.uuid, namespace_id, params)

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

    -- POST /api/v2/kanban/projects - Create project
    app:post("/api/v2/kanban/projects", function(self)
        local user, err = get_current_user()
        if not user then
            return api_response(401, nil, err)
        end

        local namespace_id = get_namespace_id()
        if not namespace_id then
            return api_response(400, nil, "Namespace context required")
        end

        local data = parse_json_body()

        -- Validate required fields
        local valid, validation_err = validate_required(data, { "name" })
        if not valid then
            return api_response(400, nil, validation_err)
        end

        -- Validate status if provided
        if data.status then
            local valid_statuses = { active = true, on_hold = true, completed = true, archived = true, cancelled = true }
            if not valid_statuses[data.status] then
                return api_response(400, nil, "Invalid status. Must be: active, on_hold, completed, archived, or cancelled")
            end
        end

        -- Validate visibility if provided
        if data.visibility then
            local valid_visibility = { public = true, private = true, internal = true }
            if not valid_visibility[data.visibility] then
                return api_response(400, nil, "Invalid visibility. Must be: public, private, or internal")
            end
        end

        -- Create project
        local project = KanbanProjectQueries.create({
            namespace_id = namespace_id,
            name = data.name,
            slug = data.slug,
            description = data.description,
            status = data.status or "active",
            visibility = data.visibility or "private",
            color = data.color,
            icon = data.icon,
            cover_image_url = data.cover_image_url,
            start_date = data.start_date,
            due_date = data.due_date,
            owner_user_uuid = user.uuid,
            settings = data.settings and cJson.encode(data.settings) or "{}",
            metadata = data.metadata and cJson.encode(data.metadata) or "{}"
        })

        if not project then
            return api_response(500, nil, "Failed to create project")
        end

        ngx.log(ngx.INFO, "[Kanban] Project created: ", project.uuid, " by user: ", user.uuid)

        return api_response(201, project)
    end)

    -- GET /api/v2/kanban/projects/:uuid - Get project details
    app:get("/api/v2/kanban/projects/:uuid", function(self)
        local user, err = get_current_user()
        if not user then
            return api_response(401, nil, err)
        end

        local project = KanbanProjectQueries.show(self.params.uuid, user.uuid)

        if not project then
            return api_response(404, nil, "Project not found")
        end

        -- Check access for private projects
        if project.visibility == "private" and not project.current_user_role then
            return api_response(403, nil, "Access denied to this project")
        end

        -- Get boards for the project
        project.boards = KanbanBoardQueries.getByProject(project.id)

        return api_response(200, project)
    end)

    -- PUT /api/v2/kanban/projects/:uuid - Update project
    app:put("/api/v2/kanban/projects/:uuid", function(self)
        local user, err = get_current_user()
        if not user then
            return api_response(401, nil, err)
        end

        local project = KanbanProjectQueries.show(self.params.uuid)
        if not project then
            return api_response(404, nil, "Project not found")
        end

        -- Check admin access
        if not KanbanProjectQueries.isAdmin(project.id, user.uuid) then
            return api_response(403, nil, "Only project admins can update projects")
        end

        local data = parse_json_body()

        -- Build update params (only allowed fields)
        local update_params = {}
        local allowed_fields = {
            "name", "description", "status", "visibility", "color", "icon",
            "cover_image_url", "start_date", "due_date", "settings", "metadata"
        }

        for _, field in ipairs(allowed_fields) do
            if data[field] ~= nil then
                if field == "settings" or field == "metadata" then
                    update_params[field] = type(data[field]) == "table" and cJson.encode(data[field]) or data[field]
                else
                    update_params[field] = data[field]
                end
            end
        end

        if next(update_params) == nil then
            return api_response(400, nil, "No valid fields to update")
        end

        local updated = KanbanProjectQueries.update(self.params.uuid, update_params)

        if not updated then
            return api_response(500, nil, "Failed to update project")
        end

        return api_response(200, updated)
    end)

    -- DELETE /api/v2/kanban/projects/:uuid - Archive project
    app:delete("/api/v2/kanban/projects/:uuid", function(self)
        local user, err = get_current_user()
        if not user then
            return api_response(401, nil, err)
        end

        local project = KanbanProjectQueries.show(self.params.uuid)
        if not project then
            return api_response(404, nil, "Project not found")
        end

        -- Only owner can archive
        if not KanbanProjectQueries.isOwner(project.id, user.uuid) then
            return api_response(403, nil, "Only the project owner can archive projects")
        end

        local archived = KanbanProjectQueries.archive(self.params.uuid)

        if not archived then
            return api_response(500, nil, "Failed to archive project")
        end

        ngx.log(ngx.INFO, "[Kanban] Project archived: ", self.params.uuid, " by user: ", user.uuid)

        return api_response(200, { message = "Project archived successfully" })
    end)

    -- GET /api/v2/kanban/projects/:uuid/stats - Get project statistics
    app:get("/api/v2/kanban/projects/:uuid/stats", function(self)
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

        local stats = KanbanProjectQueries.getStats(project.id)

        return api_response(200, stats)
    end)

    ----------------- Project Member Routes --------------------

    -- GET /api/v2/kanban/projects/:uuid/members - Get project members
    app:get("/api/v2/kanban/projects/:uuid/members", function(self)
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
            perPage = tonumber(self.params.perPage) or 50
        }

        local result = KanbanProjectQueries.getMembers(project.id, params)

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

    -- POST /api/v2/kanban/projects/:uuid/members - Add member to project
    app:post("/api/v2/kanban/projects/:uuid/members", function(self)
        local user, err = get_current_user()
        if not user then
            return api_response(401, nil, err)
        end

        local project = KanbanProjectQueries.show(self.params.uuid)
        if not project then
            return api_response(404, nil, "Project not found")
        end

        -- Check admin access
        if not KanbanProjectQueries.isAdmin(project.id, user.uuid) then
            return api_response(403, nil, "Only project admins can add members")
        end

        local data = parse_json_body()

        if not data.user_uuid then
            return api_response(400, nil, "user_uuid is required")
        end

        -- Validate role if provided
        local role = data.role or "member"
        local valid_roles = { admin = true, member = true, viewer = true, guest = true }
        if not valid_roles[role] then
            return api_response(400, nil, "Invalid role. Must be: admin, member, viewer, or guest")
        end

        local member, add_err = KanbanProjectQueries.addMember(
            project.id,
            data.user_uuid,
            role,
            user.uuid
        )

        if not member then
            return api_response(400, nil, add_err or "Failed to add member")
        end

        return api_response(201, member)
    end)

    -- DELETE /api/v2/kanban/projects/:uuid/members/:user_uuid - Remove member
    app:delete("/api/v2/kanban/projects/:uuid/members/:user_uuid", function(self)
        local user, err = get_current_user()
        if not user then
            return api_response(401, nil, err)
        end

        local project = KanbanProjectQueries.show(self.params.uuid)
        if not project then
            return api_response(404, nil, "Project not found")
        end

        local member_uuid = self.params.user_uuid

        -- Users can remove themselves, admins can remove others
        if member_uuid ~= user.uuid and not KanbanProjectQueries.isAdmin(project.id, user.uuid) then
            return api_response(403, nil, "Only project admins can remove other members")
        end

        local success, remove_err = KanbanProjectQueries.removeMember(project.id, member_uuid)

        if not success then
            return api_response(400, nil, remove_err or "Failed to remove member")
        end

        return api_response(200, { message = "Member removed successfully" })
    end)

    -- PUT /api/v2/kanban/projects/:uuid/members/:user_uuid/role - Update member role
    app:put("/api/v2/kanban/projects/:uuid/members/:user_uuid/role", function(self)
        local user, err = get_current_user()
        if not user then
            return api_response(401, nil, err)
        end

        local project = KanbanProjectQueries.show(self.params.uuid)
        if not project then
            return api_response(404, nil, "Project not found")
        end

        -- Check admin access
        if not KanbanProjectQueries.isAdmin(project.id, user.uuid) then
            return api_response(403, nil, "Only project admins can change roles")
        end

        local data = parse_json_body()

        if not data.role then
            return api_response(400, nil, "role is required")
        end

        local valid_roles = { admin = true, member = true, viewer = true, guest = true }
        if not valid_roles[data.role] then
            return api_response(400, nil, "Invalid role")
        end

        local updated, update_err = KanbanProjectQueries.updateMemberRole(
            project.id,
            self.params.user_uuid,
            data.role
        )

        if not updated then
            return api_response(400, nil, update_err or "Failed to update role")
        end

        return api_response(200, updated)
    end)

    -- POST /api/v2/kanban/projects/:uuid/star - Toggle starred status
    app:post("/api/v2/kanban/projects/:uuid/star", function(self)
        local user, err = get_current_user()
        if not user then
            return api_response(401, nil, err)
        end

        local project = KanbanProjectQueries.show(self.params.uuid)
        if not project then
            return api_response(404, nil, "Project not found")
        end

        local result, toggle_err = KanbanProjectQueries.toggleStarred(project.id, user.uuid)

        if not result then
            return api_response(400, nil, toggle_err or "Failed to toggle starred status")
        end

        return api_response(200, { is_starred = result.is_starred })
    end)

    ----------------- User Tasks Route --------------------

    -- GET /api/v2/kanban/my-tasks - Get tasks assigned to current user
    app:get("/api/v2/kanban/my-tasks", function(self)
        local user, err = get_current_user()
        if not user then
            return api_response(401, nil, err)
        end

        local namespace_id = get_namespace_id()
        if not namespace_id then
            return api_response(400, nil, "Namespace context required")
        end

        local params = {
            page = tonumber(self.params.page) or 1,
            perPage = tonumber(self.params.perPage) or 20
        }

        local result = KanbanTaskQueries.getByAssignee(user.uuid, namespace_id, params)

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

    ----------------- Namespace-scoped All Projects Route --------------------

    -- GET /api/v2/kanban/namespace/projects - List all projects in namespace (admin only)
    app:get("/api/v2/kanban/namespace/projects", function(self)
        local user, err = get_current_user()
        if not user then
            return api_response(401, nil, err)
        end

        local namespace_id = get_namespace_id()
        if not namespace_id then
            return api_response(400, nil, "Namespace context required")
        end

        local params = {
            page = tonumber(self.params.page) or 1,
            perPage = tonumber(self.params.perPage) or 20,
            status = self.params.status,
            search = self.params.search or self.params.q
        }

        local result = KanbanProjectQueries.getByNamespace(namespace_id, params)

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
end
