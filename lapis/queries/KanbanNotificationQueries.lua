--[[
    Kanban Notification Queries
    ===========================

    Unified notification system for the kanban project management:
    - Task assignment notifications
    - Comment and mention notifications
    - Due date reminders
    - Project invitations
    - Digest email support
]]

local KanbanNotificationModel = require "models.KanbanNotificationModel"
local KanbanNotificationPreferenceModel = require "models.KanbanNotificationPreferenceModel"
local Global = require "helper.global"
local db = require("lapis.db")
local cjson = require("cjson.safe")

local KanbanNotificationQueries = {}

--------------------------------------------------------------------------------
-- Notification Types
--------------------------------------------------------------------------------

KanbanNotificationQueries.TYPES = {
    TASK_ASSIGNED = "task_assigned",
    TASK_UNASSIGNED = "task_unassigned",
    TASK_COMMENTED = "task_commented",
    TASK_MENTIONED = "task_mentioned",
    TASK_COMPLETED = "task_completed",
    TASK_STATUS_CHANGED = "task_status_changed",
    TASK_DUE_SOON = "task_due_soon",
    TASK_OVERDUE = "task_overdue",
    PROJECT_INVITED = "project_invited",
    PROJECT_REMOVED = "project_removed",
    PROJECT_ROLE_CHANGED = "project_role_changed",
    SPRINT_STARTED = "sprint_started",
    SPRINT_ENDED = "sprint_ended",
    CHECKLIST_COMPLETED = "checklist_completed",
    COMMENT_REPLY = "comment_reply",
    COMMENT_MENTIONED = "comment_mentioned",
    GENERAL = "general"
}

--------------------------------------------------------------------------------
-- Create Notifications
--------------------------------------------------------------------------------

--- Create a notification
-- @param params table Notification parameters
-- @return table|nil Created notification or nil
function KanbanNotificationQueries.create(params)
    if not params.uuid then
        params.uuid = Global.generateUUID()
    end

    -- Don't notify the actor about their own actions
    if params.actor_user_uuid and params.recipient_user_uuid == params.actor_user_uuid then
        return nil
    end

    -- Check user preferences before creating
    local should_notify = KanbanNotificationQueries.shouldNotify(
        params.recipient_user_uuid,
        params.type,
        params.project_id
    )

    if not should_notify then
        return nil
    end

    params.created_at = db.raw("NOW()")

    local notification = KanbanNotificationModel:create(params, { returning = "*" })

    if notification then
        ngx.log(ngx.DEBUG, "[Notification] Created: ", notification.uuid,
            " type: ", params.type, " for user: ", params.recipient_user_uuid)
    end

    return notification
end

--- Create task assignment notification
-- @param task table Task data
-- @param assignee_uuid string Assigned user UUID
-- @param assigner_uuid string User who assigned
-- @param namespace_id number Namespace ID
-- @return table|nil Created notification
function KanbanNotificationQueries.notifyTaskAssigned(task, assignee_uuid, assigner_uuid, namespace_id)
    return KanbanNotificationQueries.create({
        namespace_id = namespace_id,
        recipient_user_uuid = assignee_uuid,
        type = KanbanNotificationQueries.TYPES.TASK_ASSIGNED,
        title = "New Task Assigned",
        message = string.format("You've been assigned to task #%d: %s", task.task_number, task.title),
        action_url = string.format("/projects/%s/tasks/%s", task.project_uuid or "", task.uuid),
        project_id = task.project_id,
        task_id = task.id,
        actor_user_uuid = assigner_uuid,
        priority = "normal",
        group_key = "task_assigned_" .. task.uuid
    })
end

--- Create task comment notification
-- @param task table Task data
-- @param comment table Comment data
-- @param commenter_uuid string User who commented
-- @param namespace_id number Namespace ID
-- @param mentioned_uuids table|nil List of mentioned user UUIDs
-- @return table[] Created notifications
function KanbanNotificationQueries.notifyTaskCommented(task, comment, commenter_uuid, namespace_id, mentioned_uuids)
    local notifications = {}

    -- Get all assignees and reporter
    local recipients = db.query([[
        SELECT DISTINCT user_uuid FROM (
            SELECT user_uuid FROM kanban_task_assignees WHERE task_id = ? AND deleted_at IS NULL
            UNION
            SELECT reporter_user_uuid as user_uuid FROM kanban_tasks WHERE id = ?
        ) combined
        WHERE user_uuid != ?
    ]], task.id, task.id, commenter_uuid)

    for _, recipient in ipairs(recipients) do
        local notif = KanbanNotificationQueries.create({
            namespace_id = namespace_id,
            recipient_user_uuid = recipient.user_uuid,
            type = KanbanNotificationQueries.TYPES.TASK_COMMENTED,
            title = "New Comment",
            message = string.format("New comment on task #%d: %s", task.task_number, task.title),
            action_url = string.format("/projects/%s/tasks/%s#comment-%s", task.project_uuid or "", task.uuid,
                comment.uuid),
            project_id = task.project_id,
            task_id = task.id,
            comment_id = comment.id,
            actor_user_uuid = commenter_uuid,
            priority = "normal",
            group_key = "task_comment_" .. task.uuid
        })
        if notif then
            table.insert(notifications, notif)
        end
    end

    -- Send mention notifications (higher priority)
    if mentioned_uuids then
        for _, mentioned_uuid in ipairs(mentioned_uuids) do
            local notif = KanbanNotificationQueries.create({
                namespace_id = namespace_id,
                recipient_user_uuid = mentioned_uuid,
                type = KanbanNotificationQueries.TYPES.TASK_MENTIONED,
                title = "You were mentioned",
                message = string.format("You were mentioned in a comment on task #%d: %s", task.task_number, task.title),
                action_url = string.format("/projects/%s/tasks/%s#comment-%s", task.project_uuid or "", task.uuid,
                    comment.uuid),
                project_id = task.project_id,
                task_id = task.id,
                comment_id = comment.id,
                actor_user_uuid = commenter_uuid,
                priority = "high",
                group_key = "task_mention_" .. task.uuid .. "_" .. mentioned_uuid
            })
            if notif then
                table.insert(notifications, notif)
            end
        end
    end

    return notifications
end

--- Create task status change notification
-- @param task table Task data
-- @param old_status string Previous status
-- @param new_status string New status
-- @param changer_uuid string User who changed status
-- @param namespace_id number Namespace ID
-- @return table[] Created notifications
function KanbanNotificationQueries.notifyTaskStatusChanged(task, old_status, new_status, changer_uuid, namespace_id)
    local notifications = {}

    -- Only notify for significant status changes
    if new_status == "completed" then
        -- Notify reporter
        if task.reporter_user_uuid and task.reporter_user_uuid ~= changer_uuid then
            local notif = KanbanNotificationQueries.create({
                namespace_id = namespace_id,
                recipient_user_uuid = task.reporter_user_uuid,
                type = KanbanNotificationQueries.TYPES.TASK_COMPLETED,
                title = "Task Completed",
                message = string.format("Task #%d: %s has been completed", task.task_number, task.title),
                action_url = string.format("/projects/%s/tasks/%s", task.project_uuid or "", task.uuid),
                project_id = task.project_id,
                task_id = task.id,
                actor_user_uuid = changer_uuid,
                priority = "normal"
            })
            if notif then
                table.insert(notifications, notif)
            end
        end
    end

    return notifications
end

--- Create project invitation notification
-- @param project table Project data
-- @param invitee_uuid string Invited user UUID
-- @param inviter_uuid string User who invited
-- @param role string Assigned role
-- @param namespace_id number Namespace ID
-- @return table|nil Created notification
function KanbanNotificationQueries.notifyProjectInvited(project, invitee_uuid, inviter_uuid, role, namespace_id)
    return KanbanNotificationQueries.create({
        namespace_id = namespace_id,
        recipient_user_uuid = invitee_uuid,
        type = KanbanNotificationQueries.TYPES.PROJECT_INVITED,
        title = "Project Invitation",
        message = string.format("You've been added to project '%s' as %s", project.name, role),
        action_url = string.format("/projects/%s", project.uuid),
        project_id = project.id,
        actor_user_uuid = inviter_uuid,
        priority = "high"
    })
end

--------------------------------------------------------------------------------
-- Query Operations
--------------------------------------------------------------------------------

--- Get notifications for a user
-- @param user_uuid string User UUID
-- @param params table Filter parameters
-- @return table { data, total, unread_count }
function KanbanNotificationQueries.getByUser(user_uuid, params)
    params = params or {}
    local page = params.page or 1
    local perPage = params.perPage or 20
    local offset = (page - 1) * perPage

    local where_clauses = { "n.recipient_user_uuid = ?", "n.deleted_at IS NULL" }
    local where_values = { user_uuid }

    if params.unread_only then
        table.insert(where_clauses, "n.is_read = false")
    end

    if params.type then
        table.insert(where_clauses, "n.type = ?")
        table.insert(where_values, params.type)
    end

    if params.project_id then
        table.insert(where_clauses, "n.project_id = ?")
        table.insert(where_values, params.project_id)
    end

    local where_sql = table.concat(where_clauses, " AND ")

    local sql = string.format([[
        SELECT n.*,
               p.name as project_name,
               p.uuid as project_uuid,
               t.title as task_title,
               t.task_number,
               t.uuid as task_uuid,
               actor.first_name as actor_first_name,
               actor.last_name as actor_last_name
        FROM kanban_notifications n
        LEFT JOIN kanban_projects p ON p.id = n.project_id
        LEFT JOIN kanban_tasks t ON t.id = n.task_id
        LEFT JOIN users actor ON actor.uuid = n.actor_user_uuid
        WHERE %s
        ORDER BY n.created_at DESC
        LIMIT ? OFFSET ?
    ]], where_sql)

    table.insert(where_values, perPage)
    table.insert(where_values, offset)

    local notifications = db.query(sql, table.unpack(where_values))

    -- Count queries
    local count_values = { user_uuid }
    local count_sql = [[
        SELECT COUNT(*) as total FROM kanban_notifications
        WHERE recipient_user_uuid = ? AND deleted_at IS NULL
    ]]
    local count_result = db.query(count_sql, user_uuid)
    local total = count_result and count_result[1] and count_result[1].total or 0

    local unread_sql = [[
        SELECT COUNT(*) as unread FROM kanban_notifications
        WHERE recipient_user_uuid = ? AND deleted_at IS NULL AND is_read = false
    ]]
    local unread_result = db.query(unread_sql, user_uuid)
    local unread_count = unread_result and unread_result[1] and unread_result[1].unread or 0

    return {
        data = notifications,
        total = tonumber(total),
        unread_count = tonumber(unread_count)
    }
end

--- Mark notification as read
-- @param uuid string Notification UUID
-- @param user_uuid string User UUID (for verification)
-- @return boolean Success
function KanbanNotificationQueries.markAsRead(uuid, user_uuid)
    local notification = KanbanNotificationModel:find({ uuid = uuid })
    if not notification then
        return false
    end

    if notification.recipient_user_uuid ~= user_uuid then
        return false
    end

    notification:update({
        is_read = true,
        read_at = db.raw("NOW()")
    })

    return true
end

--- Mark all notifications as read
-- @param user_uuid string User UUID
-- @param project_id number|nil Optional project filter
-- @return number Count of updated notifications
function KanbanNotificationQueries.markAllAsRead(user_uuid, project_id)
    local sql
    local result

    if project_id then
        sql = [[
            UPDATE kanban_notifications
            SET is_read = true, read_at = NOW()
            WHERE recipient_user_uuid = ? AND project_id = ? AND is_read = false AND deleted_at IS NULL
        ]]
        result = db.query(sql, user_uuid, project_id)
    else
        sql = [[
            UPDATE kanban_notifications
            SET is_read = true, read_at = NOW()
            WHERE recipient_user_uuid = ? AND is_read = false AND deleted_at IS NULL
        ]]
        result = db.query(sql, user_uuid)
    end

    return result and result.affected_rows or 0
end

--- Delete a notification
-- @param uuid string Notification UUID
-- @param user_uuid string User UUID (for verification)
-- @return boolean Success
function KanbanNotificationQueries.delete(uuid, user_uuid)
    local notification = KanbanNotificationModel:find({ uuid = uuid })
    if not notification then
        return false
    end

    if notification.recipient_user_uuid ~= user_uuid then
        return false
    end

    notification:update({
        deleted_at = db.raw("NOW()")
    })

    return true
end

--- Get unread count for a user
-- @param user_uuid string User UUID
-- @return number Unread count
function KanbanNotificationQueries.getUnreadCount(user_uuid)
    local result = db.query([[
        SELECT COUNT(*) as count FROM kanban_notifications
        WHERE recipient_user_uuid = ? AND is_read = false AND deleted_at IS NULL
    ]], user_uuid)

    return result and result[1] and tonumber(result[1].count) or 0
end

--------------------------------------------------------------------------------
-- Preference Operations
--------------------------------------------------------------------------------

--- Check if user should receive a notification
-- @param user_uuid string User UUID
-- @param notification_type string Notification type
-- @param project_id number|nil Project ID
-- @return boolean Should notify
function KanbanNotificationQueries.shouldNotify(user_uuid, notification_type, project_id)
    -- Get project-specific preferences first, then fall back to global
    local pref = db.query([[
        SELECT * FROM kanban_notification_preferences
        WHERE user_uuid = ? AND (project_id = ? OR project_id IS NULL)
        ORDER BY project_id DESC NULLS LAST
        LIMIT 1
    ]], user_uuid, project_id)

    if not pref or #pref == 0 then
        -- No preferences set, use defaults (notify for everything)
        return true
    end

    local preference = pref[1]

    -- Check if in-app notifications are disabled globally
    if not preference.in_app_enabled then
        return false
    end

    -- Check type-specific preferences
    if preference.preferences and preference.preferences ~= "" then
        local prefs = cjson.decode(preference.preferences)
        if prefs and prefs[notification_type] == false then
            return false
        end
    end

    return true
end

--- Get or create notification preferences
-- @param user_uuid string User UUID
-- @param project_id number|nil Project ID (nil for global)
-- @return table Preferences
function KanbanNotificationQueries.getPreferences(user_uuid, project_id)
    local pref

    if project_id then
        pref = KanbanNotificationPreferenceModel:find({
            user_uuid = user_uuid,
            project_id = project_id
        })
    else
        local result = db.query([[
            SELECT * FROM kanban_notification_preferences
            WHERE user_uuid = ? AND project_id IS NULL
            LIMIT 1
        ]], user_uuid)
        if result and #result > 0 then
            pref = result[1]
        end
    end

    if pref then
        return pref
    end

    -- Return defaults
    return {
        email_enabled = true,
        push_enabled = true,
        in_app_enabled = true,
        digest_frequency = "instant",
        preferences = {}
    }
end

--- Update notification preferences
-- @param user_uuid string User UUID
-- @param project_id number|nil Project ID (nil for global)
-- @param params table Preference parameters
-- @return table Updated preferences
function KanbanNotificationQueries.updatePreferences(user_uuid, project_id, params)
    local existing

    if project_id then
        existing = KanbanNotificationPreferenceModel:find({
            user_uuid = user_uuid,
            project_id = project_id
        })
    else
        local result = db.query([[
            SELECT * FROM kanban_notification_preferences
            WHERE user_uuid = ? AND project_id IS NULL
            LIMIT 1
        ]], user_uuid)
        if result and #result > 0 then
            existing = KanbanNotificationPreferenceModel:find({ id = result[1].id })
        end
    end

    if existing then
        params.updated_at = db.raw("NOW()")
        if params.preferences and type(params.preferences) == "table" then
            params.preferences = cjson.encode(params.preferences)
        end
        return existing:update(params, { returning = "*" })
    else
        -- Create new
        params.user_uuid = user_uuid
        params.project_id = project_id
        params.created_at = db.raw("NOW()")
        params.updated_at = db.raw("NOW()")
        if params.preferences and type(params.preferences) == "table" then
            params.preferences = cjson.encode(params.preferences)
        end
        return KanbanNotificationPreferenceModel:create(params, { returning = "*" })
    end
end

return KanbanNotificationQueries
