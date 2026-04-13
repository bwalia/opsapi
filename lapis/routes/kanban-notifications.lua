--[[
    Kanban Notifications API Routes
    ================================

    RESTful API for notification management.

    Notification Endpoints:
    - GET    /api/v2/kanban/notifications              - Get user's notifications
    - GET    /api/v2/kanban/notifications/unread-count - Get unread count
    - PUT    /api/v2/kanban/notifications/:uuid/read   - Mark as read
    - POST   /api/v2/kanban/notifications/mark-all-read - Mark all as read
    - DELETE /api/v2/kanban/notifications/:uuid        - Delete notification

    Preference Endpoints:
    - GET    /api/v2/kanban/notification-preferences           - Get preferences
    - PUT    /api/v2/kanban/notification-preferences           - Update global preferences
    - GET    /api/v2/kanban/projects/:uuid/notification-preferences  - Get project preferences
    - PUT    /api/v2/kanban/projects/:uuid/notification-preferences  - Update project preferences
]]

local cJson = require("cjson")
local KanbanNotificationQueries = require "queries.KanbanNotificationQueries"
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

    ----------------- Notification Routes --------------------

    -- GET /api/v2/kanban/notifications - Get user's notifications
    app:get("/api/v2/kanban/notifications", function(self)
        local user, err = get_current_user()
        if not user then
            return api_response(401, nil, err)
        end

        local params = {
            page = tonumber(self.params.page) or 1,
            perPage = tonumber(self.params.perPage) or 20,
            unread_only = self.params.unread_only == "true",
            type = self.params.type,
            project_id = self.params.project_id and tonumber(self.params.project_id)
        }

        local result = KanbanNotificationQueries.getByUser(user.uuid, params)

        return {
            status = 200,
            json = {
                success = true,
                data = result.data,
                meta = {
                    total = result.total,
                    unread_count = result.unread_count,
                    page = params.page,
                    perPage = params.perPage
                }
            }
        }
    end)

    -- GET /api/v2/kanban/notifications/unread-count - Get unread count
    app:get("/api/v2/kanban/notifications/unread-count", function(self)
        local user, err = get_current_user()
        if not user then
            return api_response(401, nil, err)
        end

        local count = KanbanNotificationQueries.getUnreadCount(user.uuid)

        return api_response(200, { unread_count = count })
    end)

    -- PUT /api/v2/kanban/notifications/:uuid/read - Mark as read
    app:put("/api/v2/kanban/notifications/:uuid/read", function(self)
        local user, err = get_current_user()
        if not user then
            return api_response(401, nil, err)
        end

        local success = KanbanNotificationQueries.markAsRead(
            self.params.uuid,
            user.uuid
        )

        if not success then
            return api_response(404, nil, "Notification not found")
        end

        return api_response(200, { message = "Marked as read" })
    end)

    -- POST /api/v2/kanban/notifications/mark-all-read - Mark all as read
    app:post("/api/v2/kanban/notifications/mark-all-read", function(self)
        local user, err = get_current_user()
        if not user then
            return api_response(401, nil, err)
        end

        local data = parse_request_body()
        local project_id = data.project_id and tonumber(data.project_id)

        local count = KanbanNotificationQueries.markAllAsRead(user.uuid, project_id)

        return api_response(200, {
            message = "Marked all as read",
            updated_count = count
        })
    end)

    -- DELETE /api/v2/kanban/notifications/:uuid - Delete notification
    app:delete("/api/v2/kanban/notifications/:uuid", function(self)
        local user, err = get_current_user()
        if not user then
            return api_response(401, nil, err)
        end

        local success = KanbanNotificationQueries.delete(
            self.params.uuid,
            user.uuid
        )

        if not success then
            return api_response(404, nil, "Notification not found")
        end

        return api_response(200, { message = "Notification deleted" })
    end)

    ----------------- Preference Routes --------------------

    -- GET /api/v2/kanban/notification-preferences - Get global preferences
    app:get("/api/v2/kanban/notification-preferences", function(self)
        local user, err = get_current_user()
        if not user then
            return api_response(401, nil, err)
        end

        local preferences = KanbanNotificationQueries.getPreferences(user.uuid, nil)

        return api_response(200, preferences)
    end)

    -- PUT /api/v2/kanban/notification-preferences - Update global preferences
    app:put("/api/v2/kanban/notification-preferences", function(self)
        local user, err = get_current_user()
        if not user then
            return api_response(401, nil, err)
        end

        local data = parse_request_body()

        local update_params = {}
        local allowed_fields = {
            "email_enabled", "push_enabled", "in_app_enabled",
            "digest_frequency", "digest_hour", "digest_day",
            "quiet_hours_enabled", "quiet_hours_start", "quiet_hours_end",
            "timezone", "preferences"
        }

        for _, field in ipairs(allowed_fields) do
            if data[field] ~= nil then
                update_params[field] = data[field]
            end
        end

        local updated = KanbanNotificationQueries.updatePreferences(
            user.uuid,
            nil,
            update_params
        )

        return api_response(200, updated)
    end)

    -- GET /api/v2/kanban/projects/:uuid/notification-preferences - Get project preferences
    app:get("/api/v2/kanban/projects/:uuid/notification-preferences", function(self)
        local user, err = get_current_user()
        if not user then
            return api_response(401, nil, err)
        end

        local project = KanbanProjectQueries.show(self.params.uuid)
        if not project then
            return api_response(404, nil, "Project not found")
        end

        local preferences = KanbanNotificationQueries.getPreferences(user.uuid, project.id)

        return api_response(200, preferences)
    end)

    -- PUT /api/v2/kanban/projects/:uuid/notification-preferences - Update project preferences
    app:put("/api/v2/kanban/projects/:uuid/notification-preferences", function(self)
        local user, err = get_current_user()
        if not user then
            return api_response(401, nil, err)
        end

        local project = KanbanProjectQueries.show(self.params.uuid)
        if not project then
            return api_response(404, nil, "Project not found")
        end

        local data = parse_request_body()

        local update_params = {}
        local allowed_fields = {
            "email_enabled", "push_enabled", "in_app_enabled",
            "digest_frequency", "preferences"
        }

        for _, field in ipairs(allowed_fields) do
            if data[field] ~= nil then
                update_params[field] = data[field]
            end
        end

        local updated = KanbanNotificationQueries.updatePreferences(
            user.uuid,
            project.id,
            update_params
        )

        return api_response(200, updated)
    end)
end
