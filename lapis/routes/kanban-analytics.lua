--[[
    Kanban Analytics API Routes
    ============================

    RESTful API for project analytics and reporting.

    Project Analytics:
    - GET    /api/v2/kanban/projects/:uuid/analytics          - Get project stats
    - GET    /api/v2/kanban/projects/:uuid/completion-trend   - Get completion trend
    - GET    /api/v2/kanban/projects/:uuid/priority-distribution - Get priority stats

    Team Analytics:
    - GET    /api/v2/kanban/projects/:uuid/team-workload      - Get team workload
    - GET    /api/v2/kanban/projects/:uuid/member-activity    - Get member activity

    Cycle Time Analytics:
    - GET    /api/v2/kanban/projects/:uuid/cycle-time         - Get cycle time analysis

    Activity Feed:
    - GET    /api/v2/kanban/projects/:uuid/activity           - Get activity feed
    - GET    /api/v2/kanban/projects/:uuid/activity-summary   - Get activity summary

    Label Analytics:
    - GET    /api/v2/kanban/projects/:uuid/label-stats        - Get label statistics
]]

local cJson = require("cjson")
local KanbanAnalyticsQueries = require "queries.KanbanAnalyticsQueries"
local KanbanProjectQueries = require "queries.KanbanProjectQueries"
local db = require("lapis.db")

return function(app)
    ----------------- Helper Functions --------------------

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

    ----------------- Project Analytics Routes --------------------

    -- GET /api/v2/kanban/projects/:uuid/analytics - Get project stats
    app:get("/api/v2/kanban/projects/:uuid/analytics", function(self)
        local user, err = get_current_user()
        if not user then
            return api_response(401, nil, err)
        end

        local project = KanbanProjectQueries.show(self.params.uuid)
        if not project then
            return api_response(404, nil, "Project not found")
        end

        if not KanbanProjectQueries.isMember(project.id, user.uuid) then
            return api_response(403, nil, "Access denied")
        end

        local stats = KanbanAnalyticsQueries.getProjectStats(project.id)

        return api_response(200, stats)
    end)

    -- GET /api/v2/kanban/projects/:uuid/completion-trend - Get completion trend
    app:get("/api/v2/kanban/projects/:uuid/completion-trend", function(self)
        local user, err = get_current_user()
        if not user then
            return api_response(401, nil, err)
        end

        local project = KanbanProjectQueries.show(self.params.uuid)
        if not project then
            return api_response(404, nil, "Project not found")
        end

        if not KanbanProjectQueries.isMember(project.id, user.uuid) then
            return api_response(403, nil, "Access denied")
        end

        local days = tonumber(self.params.days) or 30

        local trend = KanbanAnalyticsQueries.getCompletionTrend(project.id, days)

        return api_response(200, {
            days = days,
            trend = trend
        })
    end)

    -- GET /api/v2/kanban/projects/:uuid/priority-distribution - Get priority stats
    app:get("/api/v2/kanban/projects/:uuid/priority-distribution", function(self)
        local user, err = get_current_user()
        if not user then
            return api_response(401, nil, err)
        end

        local project = KanbanProjectQueries.show(self.params.uuid)
        if not project then
            return api_response(404, nil, "Project not found")
        end

        if not KanbanProjectQueries.isMember(project.id, user.uuid) then
            return api_response(403, nil, "Access denied")
        end

        local distribution = KanbanAnalyticsQueries.getPriorityDistribution(project.id)

        return api_response(200, distribution)
    end)

    ----------------- Team Analytics Routes --------------------

    -- GET /api/v2/kanban/projects/:uuid/team-workload - Get team workload
    app:get("/api/v2/kanban/projects/:uuid/team-workload", function(self)
        local user, err = get_current_user()
        if not user then
            return api_response(401, nil, err)
        end

        local project = KanbanProjectQueries.show(self.params.uuid)
        if not project then
            return api_response(404, nil, "Project not found")
        end

        if not KanbanProjectQueries.isMember(project.id, user.uuid) then
            return api_response(403, nil, "Access denied")
        end

        local workload = KanbanAnalyticsQueries.getTeamWorkload(project.id)

        return api_response(200, workload)
    end)

    -- GET /api/v2/kanban/projects/:uuid/member-activity - Get member activity
    app:get("/api/v2/kanban/projects/:uuid/member-activity", function(self)
        local user, err = get_current_user()
        if not user then
            return api_response(401, nil, err)
        end

        local project = KanbanProjectQueries.show(self.params.uuid)
        if not project then
            return api_response(404, nil, "Project not found")
        end

        if not KanbanProjectQueries.isMember(project.id, user.uuid) then
            return api_response(403, nil, "Access denied")
        end

        local member_uuid = self.params.user_uuid
        if not member_uuid then
            return api_response(400, nil, "user_uuid query parameter is required")
        end

        local days = tonumber(self.params.days) or 30

        local activity = KanbanAnalyticsQueries.getMemberActivity(project.id, member_uuid, days)

        return api_response(200, {
            user_uuid = member_uuid,
            days = days,
            activity = activity
        })
    end)

    ----------------- Cycle Time Analytics Routes --------------------

    -- GET /api/v2/kanban/projects/:uuid/cycle-time - Get cycle time analysis
    app:get("/api/v2/kanban/projects/:uuid/cycle-time", function(self)
        local user, err = get_current_user()
        if not user then
            return api_response(401, nil, err)
        end

        local project = KanbanProjectQueries.show(self.params.uuid)
        if not project then
            return api_response(404, nil, "Project not found")
        end

        if not KanbanProjectQueries.isMember(project.id, user.uuid) then
            return api_response(403, nil, "Access denied")
        end

        local by_column = KanbanAnalyticsQueries.getCycleTimeByColumn(project.id)
        local by_priority = KanbanAnalyticsQueries.getCycleTimeByPriority(project.id)

        return api_response(200, {
            by_column = by_column,
            by_priority = by_priority
        })
    end)

    ----------------- Activity Feed Routes --------------------

    -- GET /api/v2/kanban/projects/:uuid/activity - Get activity feed
    app:get("/api/v2/kanban/projects/:uuid/activity", function(self)
        local user, err = get_current_user()
        if not user then
            return api_response(401, nil, err)
        end

        local project = KanbanProjectQueries.show(self.params.uuid)
        if not project then
            return api_response(404, nil, "Project not found")
        end

        if not KanbanProjectQueries.isMember(project.id, user.uuid) then
            return api_response(403, nil, "Access denied")
        end

        local params = {
            page = tonumber(self.params.page) or 1,
            perPage = tonumber(self.params.perPage) or 50,
            user_uuid = self.params.user_uuid,
            action = self.params.action,
            since = self.params.since
        }

        local result = KanbanAnalyticsQueries.getProjectActivityFeed(project.id, params)

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

    -- GET /api/v2/kanban/projects/:uuid/activity-summary - Get activity summary
    app:get("/api/v2/kanban/projects/:uuid/activity-summary", function(self)
        local user, err = get_current_user()
        if not user then
            return api_response(401, nil, err)
        end

        local project = KanbanProjectQueries.show(self.params.uuid)
        if not project then
            return api_response(404, nil, "Project not found")
        end

        if not KanbanProjectQueries.isMember(project.id, user.uuid) then
            return api_response(403, nil, "Access denied")
        end

        local hours = tonumber(self.params.hours) or 24

        local summary = KanbanAnalyticsQueries.getRecentActivitySummary(project.id, hours)

        return api_response(200, summary)
    end)

    ----------------- Label Analytics Routes --------------------

    -- GET /api/v2/kanban/projects/:uuid/label-stats - Get label statistics
    app:get("/api/v2/kanban/projects/:uuid/label-stats", function(self)
        local user, err = get_current_user()
        if not user then
            return api_response(401, nil, err)
        end

        local project = KanbanProjectQueries.show(self.params.uuid)
        if not project then
            return api_response(404, nil, "Project not found")
        end

        if not KanbanProjectQueries.isMember(project.id, user.uuid) then
            return api_response(403, nil, "Access denied")
        end

        local label_stats = KanbanAnalyticsQueries.getLabelStats(project.id)

        return api_response(200, label_stats)
    end)
end
