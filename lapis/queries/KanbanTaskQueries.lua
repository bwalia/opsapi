--[[
    Kanban Task Queries
    ===================

    Query helpers for task operations including assignment,
    comments, checklists, and chat channel integration.
]]

local KanbanTaskModel = require "models.KanbanTaskModel"
local KanbanTaskAssigneeModel = require "models.KanbanTaskAssigneeModel"
local KanbanTaskCommentModel = require "models.KanbanTaskCommentModel"
local KanbanTaskAttachmentModel = require "models.KanbanTaskAttachmentModel"
local KanbanTaskChecklistModel = require "models.KanbanTaskChecklistModel"
local KanbanChecklistItemModel = require "models.KanbanChecklistItemModel"
local KanbanTaskActivityModel = require "models.KanbanTaskActivityModel"
local KanbanTaskLabelLinkModel = require "models.KanbanTaskLabelLinkModel"
local ChatChannelModel = require "models.ChatChannelModel"
local ChatChannelMemberModel = require "models.ChatChannelMemberModel"
local Global = require "helper.global"
local db = require("lapis.db")
local cjson = require("cjson.safe")

local KanbanTaskQueries = {}

--------------------------------------------------------------------------------
-- Task CRUD Operations
--------------------------------------------------------------------------------

--- Create a new task
-- @param params table Task parameters
-- @return table|nil Created task
function KanbanTaskQueries.create(params)
    if not params.uuid then
        params.uuid = Global.generateUUID()
    end

    -- Generate task number for the board
    local task_num_result = db.query([[
        SELECT COALESCE(MAX(task_number), 0) + 1 as next_num
        FROM kanban_tasks WHERE board_id = ?
    ]], params.board_id)
    params.task_number = task_num_result[1].next_num

    -- Get next position in column
    if not params.position and params.column_id then
        local pos_result = db.query([[
            SELECT COALESCE(MAX(position), -1) + 1 as next_pos
            FROM kanban_tasks WHERE column_id = ? AND archived_at IS NULL
        ]], params.column_id)
        params.position = pos_result[1].next_pos
    end

    -- Remove nil values for fields with foreign key constraints
    -- to prevent inserting defaults that violate FK
    if params.parent_task_id == nil or params.parent_task_id == "" or params.parent_task_id == 0 then
        params.parent_task_id = nil
    end
    if params.sprint_id == nil or params.sprint_id == "" or params.sprint_id == 0 then
        params.sprint_id = nil
    end

    params.created_at = db.raw("NOW()")
    params.updated_at = db.raw("NOW()")

    -- Build clean params excluding nil values
    local clean_params = {}
    for k, v in pairs(params) do
        if v ~= nil then
            clean_params[k] = v
        end
    end

    return KanbanTaskModel:create(clean_params, { returning = "*" })
end

--- Get tasks for a board
-- @param board_id number Board ID
-- @param params table Filter parameters
-- @return table { data, total }
function KanbanTaskQueries.getByBoard(board_id, params)
    params = params or {}
    local page = params.page or 1
    local perPage = params.perPage or 50
    local offset = (page - 1) * perPage

    local where_clauses = { "t.board_id = ?", "t.archived_at IS NULL" }
    local where_values = { board_id }

    if params.column_id then
        table.insert(where_clauses, "t.column_id = ?")
        table.insert(where_values, params.column_id)
    end

    if params.status then
        table.insert(where_clauses, "t.status = ?")
        table.insert(where_values, params.status)
    end

    if params.priority then
        table.insert(where_clauses, "t.priority = ?")
        table.insert(where_values, params.priority)
    end

    if params.assignee_uuid then
        table.insert(where_clauses, "EXISTS (SELECT 1 FROM kanban_task_assignees WHERE task_id = t.id AND user_uuid = ?)")
        table.insert(where_values, params.assignee_uuid)
    end

    if params.search then
        table.insert(where_clauses, "t.search_vector @@ plainto_tsquery('english', ?)")
        table.insert(where_values, params.search)
    end

    -- Exclude subtasks from main list unless requested
    if not params.include_subtasks then
        table.insert(where_clauses, "t.parent_task_id IS NULL")
    end

    local where_sql = table.concat(where_clauses, " AND ")

    local sql = string.format([[
        SELECT t.*,
               c.name as column_name,
               c.color as column_color
        FROM kanban_tasks t
        LEFT JOIN kanban_columns c ON c.id = t.column_id
        WHERE %s
        ORDER BY t.column_id ASC, t.position ASC
        LIMIT ? OFFSET ?
    ]], where_sql)

    table.insert(where_values, perPage)
    table.insert(where_values, offset)

    local tasks = db.query(sql, unpack(where_values))

    -- Get assignees and labels for each task
    for _, task in ipairs(tasks) do
        task.assignees = KanbanTaskQueries.getAssignees(task.id)
        task.labels = KanbanTaskQueries.getLabels(task.id)
    end

    -- Count query
    local count_sql = string.format([[
        SELECT COUNT(*) as total FROM kanban_tasks t WHERE %s
    ]], where_sql)

    local count_values = {}
    for i = 1, #where_values - 2 do
        table.insert(count_values, where_values[i])
    end

    local count_result = db.query(count_sql, unpack(count_values))
    local total = count_result and count_result[1] and count_result[1].total or 0

    return {
        data = tasks,
        total = tonumber(total)
    }
end

--- Get tasks assigned to a user
-- @param user_uuid string User UUID
-- @param namespace_id number Namespace ID
-- @param params table Filter parameters
-- @return table { data, total }
function KanbanTaskQueries.getByAssignee(user_uuid, namespace_id, params)
    params = params or {}
    local page = params.page or 1
    local perPage = params.perPage or 20
    local offset = (page - 1) * perPage

    local sql = [[
        SELECT t.*,
               c.name as column_name,
               b.name as board_name,
               p.name as project_name,
               p.uuid as project_uuid
        FROM kanban_tasks t
        INNER JOIN kanban_task_assignees ta ON ta.task_id = t.id
        INNER JOIN kanban_boards b ON b.id = t.board_id
        INNER JOIN kanban_projects p ON p.id = b.project_id
        LEFT JOIN kanban_columns c ON c.id = t.column_id
        WHERE ta.user_uuid = ?
          AND p.namespace_id = ?
          AND t.archived_at IS NULL
          AND t.status NOT IN ('completed', 'cancelled')
        ORDER BY
            CASE t.priority
                WHEN 'critical' THEN 1
                WHEN 'high' THEN 2
                WHEN 'medium' THEN 3
                WHEN 'low' THEN 4
                ELSE 5
            END,
            t.due_date ASC NULLS LAST
        LIMIT ? OFFSET ?
    ]]

    local tasks = db.query(sql, user_uuid, namespace_id, perPage, offset)

    local count_sql = [[
        SELECT COUNT(*) as total
        FROM kanban_tasks t
        INNER JOIN kanban_task_assignees ta ON ta.task_id = t.id
        INNER JOIN kanban_boards b ON b.id = t.board_id
        INNER JOIN kanban_projects p ON p.id = b.project_id
        WHERE ta.user_uuid = ?
          AND p.namespace_id = ?
          AND t.archived_at IS NULL
          AND t.status NOT IN ('completed', 'cancelled')
    ]]
    local count_result = db.query(count_sql, user_uuid, namespace_id)
    local total = count_result and count_result[1] and count_result[1].total or 0

    return {
        data = tasks,
        total = tonumber(total)
    }
end

--- Get single task with all details
-- @param uuid string Task UUID
-- @return table|nil Task with details
function KanbanTaskQueries.show(uuid)
    local sql = [[
        SELECT t.*,
               c.name as column_name,
               c.color as column_color,
               c.uuid as column_uuid,
               b.name as board_name,
               b.uuid as board_uuid,
               p.name as project_name,
               p.uuid as project_uuid,
               p.namespace_id,
               u.first_name as reporter_first_name,
               u.last_name as reporter_last_name,
               u.email as reporter_email
        FROM kanban_tasks t
        LEFT JOIN kanban_columns c ON c.id = t.column_id
        INNER JOIN kanban_boards b ON b.id = t.board_id
        INNER JOIN kanban_projects p ON p.id = b.project_id
        LEFT JOIN users u ON u.uuid = t.reporter_user_uuid
        WHERE t.uuid = ?
    ]]

    local result = db.query(sql, uuid)
    if not result or #result == 0 then
        return nil
    end

    local task = result[1]

    -- Get assignees
    task.assignees = KanbanTaskQueries.getAssignees(task.id)

    -- Get labels
    task.labels = KanbanTaskQueries.getLabels(task.id)

    -- Get subtasks
    local subtasks_sql = [[
        SELECT * FROM kanban_tasks
        WHERE parent_task_id = ? AND archived_at IS NULL
        ORDER BY position ASC
    ]]
    task.subtasks = db.query(subtasks_sql, task.id)

    -- Get checklists with items
    task.checklists = KanbanTaskQueries.getChecklists(task.id)

    return task
end

--- Get task by ID
-- @param id number Task ID
-- @return table|nil Task
function KanbanTaskQueries.getById(id)
    return KanbanTaskModel:find({ id = id })
end

--- Update task
-- @param uuid string Task UUID
-- @param params table Update parameters
-- @param user_uuid string User performing the update (for activity log)
-- @return table|nil Updated task
function KanbanTaskQueries.update(uuid, params, user_uuid)
    local task = KanbanTaskModel:find({ uuid = uuid })
    if not task then return nil end

    -- Track changes for activity log
    local changes = {}
    for key, new_value in pairs(params) do
        if task[key] ~= new_value then
            changes[key] = { old = task[key], new = new_value }
        end
    end

    params.updated_at = db.raw("NOW()")

    -- Auto-set completed_at when status changes to completed
    if params.status == "completed" and task.status ~= "completed" then
        params.completed_at = db.raw("NOW()")
    elseif params.status and params.status ~= "completed" and task.status == "completed" then
        params.completed_at = db.raw("NULL")
    end

    local updated = task:update(params, { returning = "*" })

    -- Log activity
    if updated and user_uuid and next(changes) then
        for field, change in pairs(changes) do
            KanbanTaskQueries.logActivity(task.id, user_uuid, "updated", field, nil,
                tostring(change.old), tostring(change.new))
        end
    end

    return updated
end

--- Move task to different column
-- @param uuid string Task UUID
-- @param column_id number Target column ID
-- @param position number Position in column
-- @param user_uuid string User performing the move
-- @return table|nil Updated task
function KanbanTaskQueries.moveToColumn(uuid, column_id, position, user_uuid)
    local task = KanbanTaskModel:find({ uuid = uuid })
    if not task then return nil end

    local old_column_id = task.column_id

    -- Get column info
    local column = db.query("SELECT * FROM kanban_columns WHERE id = ?", column_id)
    if not column or #column == 0 then
        return nil, "Column not found"
    end

    local update_params = {
        column_id = column_id,
        position = position or 0,
        updated_at = db.raw("NOW()")
    }

    -- Auto-complete task if moved to done column
    if column[1].auto_close_tasks and column[1].is_done_column then
        update_params.status = "completed"
        update_params.completed_at = db.raw("NOW()")
    end

    local updated = task:update(update_params, { returning = "*" })

    -- Log activity
    if updated and user_uuid and old_column_id ~= column_id then
        KanbanTaskQueries.logActivity(task.id, user_uuid, "moved", "column_id", nil,
            tostring(old_column_id), tostring(column_id))
    end

    return updated
end

--- Archive task
-- @param uuid string Task UUID
-- @return table|nil Archived task
function KanbanTaskQueries.archive(uuid)
    local task = KanbanTaskModel:find({ uuid = uuid })
    if not task then return nil end

    return task:update({
        archived_at = db.raw("NOW()"),
        updated_at = db.raw("NOW()")
    }, { returning = "*" })
end

--- Delete task (hard delete)
-- @param uuid string Task UUID
-- @return boolean Success
function KanbanTaskQueries.destroy(uuid)
    local task = KanbanTaskModel:find({ uuid = uuid })
    if not task then return false end
    return task:delete()
end

--------------------------------------------------------------------------------
-- Task Assignment with Chat Integration
--------------------------------------------------------------------------------

--- Get task assignees
-- @param task_id number Task ID
-- @return table[] Assignees with user info
function KanbanTaskQueries.getAssignees(task_id)
    local sql = [[
        SELECT ta.*, u.email, u.first_name, u.last_name, u.username
        FROM kanban_task_assignees ta
        INNER JOIN users u ON u.uuid = ta.user_uuid
        WHERE ta.task_id = ?
        ORDER BY ta.assigned_at ASC
    ]]
    return db.query(sql, task_id)
end

--- Assign user to task and manage chat channel
-- @param task_id number Task ID
-- @param user_uuid string User UUID to assign
-- @param assigned_by string User UUID who assigned
-- @param namespace_id number Namespace ID for chat channel
-- @return table|nil Assignment result
function KanbanTaskQueries.assignUser(task_id, user_uuid, assigned_by, namespace_id)
    -- Check if already assigned
    local existing = db.query([[
        SELECT id FROM kanban_task_assignees
        WHERE task_id = ? AND user_uuid = ?
    ]], task_id, user_uuid)

    if existing and #existing > 0 then
        return nil, "User is already assigned to this task"
    end

    -- Get task details
    local task = KanbanTaskModel:find({ id = task_id })
    if not task then
        return nil, "Task not found"
    end

    -- Get project info for chat channel
    local project_info = db.query([[
        SELECT p.id, p.uuid, p.name, p.chat_channel_uuid
        FROM kanban_projects p
        INNER JOIN kanban_boards b ON b.project_id = p.id
        WHERE b.id = ?
    ]], task.board_id)

    if not project_info or #project_info == 0 then
        return nil, "Project not found"
    end

    local project = project_info[1]

    -- Create assignment
    local assignment = KanbanTaskAssigneeModel:create({
        uuid = Global.generateUUID(),
        task_id = task_id,
        user_uuid = user_uuid,
        assigned_by = assigned_by,
        assigned_at = db.raw("NOW()"),
        created_at = db.raw("NOW()")
    }, { returning = "*" })

    if not assignment then
        return nil, "Failed to create assignment"
    end

    -- Create or get task chat channel
    local chat_channel_uuid = task.chat_channel_uuid

    if not chat_channel_uuid then
        -- Create chat channel for the task
        local channel_name = string.format("%s - #%d", project.name, task.task_number)
        local channel = ChatChannelModel:create({
            uuid = Global.generateUUID(),
            name = channel_name,
            description = task.title,
            type = "private",
            created_by = assigned_by,
            namespace_id = namespace_id,
            linked_task_uuid = task.uuid,
            linked_task_id = task.id,
            created_at = db.raw("NOW()"),
            updated_at = db.raw("NOW()")
        }, { returning = "*" })

        if channel then
            chat_channel_uuid = channel.uuid

            -- Update task with chat channel
            task:update({ chat_channel_uuid = chat_channel_uuid })

            -- Add reporter to channel as admin
            if task.reporter_user_uuid then
                ChatChannelMemberModel:create({
                    uuid = Global.generateUUID(),
                    channel_uuid = chat_channel_uuid,
                    user_uuid = task.reporter_user_uuid,
                    role = "admin",
                    joined_at = db.raw("NOW()"),
                    created_at = db.raw("NOW()"),
                    updated_at = db.raw("NOW()")
                })
            end
        end
    end

    -- Add assignee to chat channel
    if chat_channel_uuid then
        -- Check if already a member
        local member_exists = db.query([[
            SELECT id FROM chat_channel_members
            WHERE channel_uuid = ? AND user_uuid = ? AND left_at IS NULL
        ]], chat_channel_uuid, user_uuid)

        if not member_exists or #member_exists == 0 then
            ChatChannelMemberModel:create({
                uuid = Global.generateUUID(),
                channel_uuid = chat_channel_uuid,
                user_uuid = user_uuid,
                role = "member",
                joined_at = db.raw("NOW()"),
                created_at = db.raw("NOW()"),
                updated_at = db.raw("NOW()")
            })
        end
    end

    -- Log activity
    KanbanTaskQueries.logActivity(task_id, assigned_by, "assigned", "assignee", nil, nil, user_uuid)

    return {
        assignment = assignment,
        chat_channel_uuid = chat_channel_uuid
    }
end

--- Unassign user from task
-- @param task_id number Task ID
-- @param user_uuid string User UUID to unassign
-- @param unassigned_by string User UUID who unassigned
-- @return boolean Success
function KanbanTaskQueries.unassignUser(task_id, user_uuid, unassigned_by)
    local assignment = KanbanTaskAssigneeModel:find({
        task_id = task_id,
        user_uuid = user_uuid
    })

    if not assignment then
        return false, "Assignment not found"
    end

    -- Get task for chat channel removal
    local task = KanbanTaskModel:find({ id = task_id })

    -- Remove from chat channel if exists
    if task and task.chat_channel_uuid then
        db.query([[
            UPDATE chat_channel_members
            SET left_at = NOW(), updated_at = NOW()
            WHERE channel_uuid = ? AND user_uuid = ?
        ]], task.chat_channel_uuid, user_uuid)
    end

    assignment:delete()

    -- Log activity
    KanbanTaskQueries.logActivity(task_id, unassigned_by, "unassigned", "assignee", nil, user_uuid, nil)

    return true
end

--------------------------------------------------------------------------------
-- Task Labels
--------------------------------------------------------------------------------

--- Get task labels
-- @param task_id number Task ID
-- @return table[] Labels
function KanbanTaskQueries.getLabels(task_id)
    local sql = [[
        SELECT l.*
        FROM kanban_task_labels l
        INNER JOIN kanban_task_label_links ll ON ll.label_id = l.id
        WHERE ll.task_id = ?
        ORDER BY l.name ASC
    ]]
    return db.query(sql, task_id)
end

--- Add label to task
-- @param task_id number Task ID
-- @param label_id number Label ID
-- @return table|nil Link
function KanbanTaskQueries.addLabel(task_id, label_id)
    -- Check if already linked
    local existing = db.query([[
        SELECT id FROM kanban_task_label_links
        WHERE task_id = ? AND label_id = ?
    ]], task_id, label_id)

    if existing and #existing > 0 then
        return nil, "Label already attached"
    end

    return KanbanTaskLabelLinkModel:create({
        task_id = task_id,
        label_id = label_id,
        created_at = db.raw("NOW()")
    }, { returning = "*" })
end

--- Remove label from task
-- @param task_id number Task ID
-- @param label_id number Label ID
-- @return boolean Success
function KanbanTaskQueries.removeLabel(task_id, label_id)
    local link = KanbanTaskLabelLinkModel:find({
        task_id = task_id,
        label_id = label_id
    })

    if not link then return false end
    return link:delete()
end

--------------------------------------------------------------------------------
-- Task Comments
--------------------------------------------------------------------------------

--- Get task comments
-- @param task_id number Task ID
-- @param params table Pagination parameters
-- @return table { data, total }
function KanbanTaskQueries.getComments(task_id, params)
    params = params or {}
    local page = params.page or 1
    local perPage = params.perPage or 20
    local offset = (page - 1) * perPage

    local sql = [[
        SELECT c.*, u.email, u.first_name, u.last_name, u.username
        FROM kanban_task_comments c
        INNER JOIN users u ON u.uuid = c.user_uuid
        WHERE c.task_id = ? AND c.deleted_at IS NULL AND c.parent_comment_id IS NULL
        ORDER BY c.created_at DESC
        LIMIT ? OFFSET ?
    ]]

    local comments = db.query(sql, task_id, perPage, offset)

    -- Get replies for each comment
    for _, comment in ipairs(comments) do
        local replies_sql = [[
            SELECT c.*, u.email, u.first_name, u.last_name, u.username
            FROM kanban_task_comments c
            INNER JOIN users u ON u.uuid = c.user_uuid
            WHERE c.parent_comment_id = ? AND c.deleted_at IS NULL
            ORDER BY c.created_at ASC
        ]]
        comment.replies = db.query(replies_sql, comment.id)
    end

    local count_sql = [[
        SELECT COUNT(*) as total
        FROM kanban_task_comments
        WHERE task_id = ? AND deleted_at IS NULL AND parent_comment_id IS NULL
    ]]
    local count_result = db.query(count_sql, task_id)
    local total = count_result and count_result[1] and count_result[1].total or 0

    return {
        data = comments,
        total = tonumber(total)
    }
end

--- Add comment to task
-- @param params table Comment parameters
-- @return table|nil Created comment
function KanbanTaskQueries.addComment(params)
    if not params.uuid then
        params.uuid = Global.generateUUID()
    end

    params.created_at = db.raw("NOW()")
    params.updated_at = db.raw("NOW()")

    local comment = KanbanTaskCommentModel:create(params, { returning = "*" })

    if comment then
        -- Log activity
        KanbanTaskQueries.logActivity(params.task_id, params.user_uuid, "commented", "comment", comment.id)
    end

    return comment
end

--- Update comment
-- @param uuid string Comment UUID
-- @param content string New content
-- @return table|nil Updated comment
function KanbanTaskQueries.updateComment(uuid, content)
    local comment = KanbanTaskCommentModel:find({ uuid = uuid })
    if not comment then return nil end

    return comment:update({
        content = content,
        is_edited = true,
        edited_at = db.raw("NOW()"),
        updated_at = db.raw("NOW()")
    }, { returning = "*" })
end

--- Delete comment (soft delete)
-- @param uuid string Comment UUID
-- @return boolean Success
function KanbanTaskQueries.deleteComment(uuid)
    local comment = KanbanTaskCommentModel:find({ uuid = uuid })
    if not comment then return false end

    comment:update({ deleted_at = db.raw("NOW()") })
    return true
end

--------------------------------------------------------------------------------
-- Task Checklists
--------------------------------------------------------------------------------

--- Get task checklists with items
-- @param task_id number Task ID
-- @return table[] Checklists with items
function KanbanTaskQueries.getChecklists(task_id)
    local sql = [[
        SELECT * FROM kanban_task_checklists
        WHERE task_id = ?
        ORDER BY position ASC
    ]]
    local checklists = db.query(sql, task_id)

    for _, checklist in ipairs(checklists) do
        local items_sql = [[
            SELECT * FROM kanban_checklist_items
            WHERE checklist_id = ?
            ORDER BY position ASC
        ]]
        checklist.items = db.query(items_sql, checklist.id)
    end

    return checklists
end

--- Create checklist
-- @param params table Checklist parameters
-- @return table|nil Created checklist
function KanbanTaskQueries.createChecklist(params)
    if not params.uuid then
        params.uuid = Global.generateUUID()
    end

    -- Get next position
    if not params.position then
        local pos_result = db.query([[
            SELECT COALESCE(MAX(position), -1) + 1 as next_pos
            FROM kanban_task_checklists WHERE task_id = ?
        ]], params.task_id)
        params.position = pos_result[1].next_pos
    end

    params.created_at = db.raw("NOW()")
    params.updated_at = db.raw("NOW()")

    return KanbanTaskChecklistModel:create(params, { returning = "*" })
end

--- Add checklist item
-- @param params table Item parameters
-- @return table|nil Created item
function KanbanTaskQueries.addChecklistItem(params)
    if not params.uuid then
        params.uuid = Global.generateUUID()
    end

    -- Get next position
    if not params.position then
        local pos_result = db.query([[
            SELECT COALESCE(MAX(position), -1) + 1 as next_pos
            FROM kanban_checklist_items WHERE checklist_id = ?
        ]], params.checklist_id)
        params.position = pos_result[1].next_pos
    end

    params.created_at = db.raw("NOW()")
    params.updated_at = db.raw("NOW()")

    return KanbanChecklistItemModel:create(params, { returning = "*" })
end

--- Toggle checklist item
-- @param uuid string Item UUID
-- @param user_uuid string User completing/uncompleting
-- @return table|nil Updated item
function KanbanTaskQueries.toggleChecklistItem(uuid, user_uuid)
    local item = KanbanChecklistItemModel:find({ uuid = uuid })
    if not item then return nil end

    local is_completed = not item.is_completed

    return item:update({
        is_completed = is_completed,
        completed_at = is_completed and db.raw("NOW()") or db.raw("NULL"),
        completed_by = is_completed and user_uuid or db.raw("NULL"),
        updated_at = db.raw("NOW()")
    }, { returning = "*" })
end

--- Delete checklist
-- @param uuid string Checklist UUID
-- @return boolean Success
function KanbanTaskQueries.deleteChecklist(uuid)
    local checklist = KanbanTaskChecklistModel:find({ uuid = uuid })
    if not checklist then return false end
    return checklist:delete()
end

--- Delete checklist item
-- @param uuid string Item UUID
-- @return boolean Success
function KanbanTaskQueries.deleteChecklistItem(uuid)
    local item = KanbanChecklistItemModel:find({ uuid = uuid })
    if not item then return false end
    return item:delete()
end

--------------------------------------------------------------------------------
-- Task Attachments
--------------------------------------------------------------------------------

--- Get task attachments
-- @param task_id number Task ID
-- @return table[] Attachments
function KanbanTaskQueries.getAttachments(task_id)
    local sql = [[
        SELECT a.*, u.first_name, u.last_name
        FROM kanban_task_attachments a
        INNER JOIN users u ON u.uuid = a.uploaded_by
        WHERE a.task_id = ? AND a.deleted_at IS NULL
        ORDER BY a.created_at DESC
    ]]
    return db.query(sql, task_id)
end

--- Add attachment
-- @param params table Attachment parameters
-- @return table|nil Created attachment
function KanbanTaskQueries.addAttachment(params)
    if not params.uuid then
        params.uuid = Global.generateUUID()
    end

    params.created_at = db.raw("NOW()")

    local attachment = KanbanTaskAttachmentModel:create(params, { returning = "*" })

    if attachment then
        -- Log activity
        KanbanTaskQueries.logActivity(params.task_id, params.uploaded_by, "attached", "attachment", attachment.id)
    end

    return attachment
end

--- Delete attachment (soft delete)
-- @param uuid string Attachment UUID
-- @return boolean Success
function KanbanTaskQueries.deleteAttachment(uuid)
    local attachment = KanbanTaskAttachmentModel:find({ uuid = uuid })
    if not attachment then return false end

    attachment:update({ deleted_at = db.raw("NOW()") })
    return true
end

--------------------------------------------------------------------------------
-- Task Activity Log
--------------------------------------------------------------------------------

--- Log task activity
-- @param task_id number Task ID
-- @param user_uuid string User UUID
-- @param action string Action performed
-- @param entity_type string|nil Type of entity affected
-- @param entity_id number|nil ID of entity affected
-- @param old_value string|nil Old value
-- @param new_value string|nil New value
-- @param metadata table|nil Additional metadata
function KanbanTaskQueries.logActivity(task_id, user_uuid, action, entity_type, entity_id, old_value, new_value, metadata)
    KanbanTaskActivityModel:create({
        uuid = Global.generateUUID(),
        task_id = task_id,
        user_uuid = user_uuid,
        action = action,
        entity_type = entity_type,
        entity_id = entity_id,
        old_value = old_value,
        new_value = new_value,
        metadata = metadata and cjson.encode(metadata) or "{}",
        created_at = db.raw("NOW()")
    })
end

--- Get task activities
-- @param task_id number Task ID
-- @param params table Pagination parameters
-- @return table { data, total }
function KanbanTaskQueries.getActivities(task_id, params)
    params = params or {}
    local page = params.page or 1
    local perPage = params.perPage or 20
    local offset = (page - 1) * perPage

    local sql = [[
        SELECT a.*, u.email, u.first_name, u.last_name, u.username
        FROM kanban_task_activities a
        INNER JOIN users u ON u.uuid = a.user_uuid
        WHERE a.task_id = ?
        ORDER BY a.created_at DESC
        LIMIT ? OFFSET ?
    ]]

    local activities = db.query(sql, task_id, perPage, offset)

    local count_sql = [[
        SELECT COUNT(*) as total FROM kanban_task_activities WHERE task_id = ?
    ]]
    local count_result = db.query(count_sql, task_id)
    local total = count_result and count_result[1] and count_result[1].total or 0

    return {
        data = activities,
        total = tonumber(total)
    }
end

return KanbanTaskQueries
