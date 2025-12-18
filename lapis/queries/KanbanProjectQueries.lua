--[[
    Kanban Project Queries
    ======================

    Query helpers for kanban project management operations.
    Projects are namespace-scoped for multi-tenant isolation.
]]

local KanbanProjectModel = require "models.KanbanProjectModel"
local KanbanProjectMemberModel = require "models.KanbanProjectMemberModel"
local KanbanBoardModel = require "models.KanbanBoardModel"
local KanbanColumnModel = require "models.KanbanColumnModel"
local Global = require "helper.global"
local db = require("lapis.db")

local KanbanProjectQueries = {}

--------------------------------------------------------------------------------
-- Project CRUD Operations
--------------------------------------------------------------------------------

--- Create a new project
-- @param params table Project parameters
-- @return table|nil Created project or nil
function KanbanProjectQueries.create(params)
    if not params.uuid then
        params.uuid = Global.generateUUID()
    end
    if not params.status then
        params.status = "active"
    end
    if not params.visibility then
        params.visibility = "private"
    end

    -- Generate slug from name if not provided
    if not params.slug and params.name then
        params.slug = params.name:lower():gsub("%s+", "-"):gsub("[^%w%-]", "")
    end

    params.created_at = db.raw("NOW()")
    params.updated_at = db.raw("NOW()")

    local project = KanbanProjectModel:create(params, { returning = "*" })

    if project then
        -- Add owner as project member with owner role
        KanbanProjectMemberModel:create({
            uuid = Global.generateUUID(),
            project_id = project.id,
            user_uuid = params.owner_user_uuid,
            role = "owner",
            joined_at = db.raw("NOW()"),
            created_at = db.raw("NOW()"),
            updated_at = db.raw("NOW()")
        })

        -- Create default board
        local board = KanbanBoardModel:create({
            uuid = Global.generateUUID(),
            project_id = project.id,
            name = "Main Board",
            description = "Default project board",
            position = 0,
            is_default = true,
            created_by = params.owner_user_uuid,
            created_at = db.raw("NOW()"),
            updated_at = db.raw("NOW()")
        })

        -- Create default columns
        if board then
            local default_columns = {
                { name = "Backlog", position = 0, color = "#6B7280" },
                { name = "To Do", position = 1, color = "#3B82F6" },
                { name = "In Progress", position = 2, color = "#F59E0B" },
                { name = "Review", position = 3, color = "#8B5CF6" },
                { name = "Done", position = 4, color = "#10B981", is_done_column = true, auto_close_tasks = true }
            }

            for _, col in ipairs(default_columns) do
                KanbanColumnModel:create({
                    uuid = Global.generateUUID(),
                    board_id = board.id,
                    name = col.name,
                    position = col.position,
                    color = col.color,
                    is_done_column = col.is_done_column or false,
                    auto_close_tasks = col.auto_close_tasks or false,
                    created_at = db.raw("NOW()"),
                    updated_at = db.raw("NOW()")
                })
            end
        end
    end

    return project
end

--- Get all projects for a namespace with pagination
-- @param namespace_id number Namespace ID
-- @param params table Pagination and filter parameters
-- @return table { data, total }
function KanbanProjectQueries.getByNamespace(namespace_id, params)
    params = params or {}
    local page = params.page or 1
    local perPage = params.perPage or 20
    local offset = (page - 1) * perPage
    local status = params.status
    local search = params.search

    local where_clauses = { "namespace_id = ?" }
    local where_values = { namespace_id }

    if status and status ~= "" then
        table.insert(where_clauses, "status = ?")
        table.insert(where_values, status)
    else
        table.insert(where_clauses, "status != 'archived'")
    end

    if search and search ~= "" then
        table.insert(where_clauses, "(name ILIKE ? OR description ILIKE ?)")
        local search_pattern = "%" .. search .. "%"
        table.insert(where_values, search_pattern)
        table.insert(where_values, search_pattern)
    end

    local where_sql = table.concat(where_clauses, " AND ")

    -- Build main query
    local sql = string.format([[
        SELECT p.*,
               (SELECT COUNT(*) FROM kanban_project_members WHERE project_id = p.id AND left_at IS NULL) as member_count,
               (SELECT COUNT(*) FROM kanban_boards WHERE project_id = p.id AND archived_at IS NULL) as board_count
        FROM kanban_projects p
        WHERE %s
        ORDER BY p.updated_at DESC NULLS LAST
        LIMIT ? OFFSET ?
    ]], where_sql)

    table.insert(where_values, perPage)
    table.insert(where_values, offset)

    local projects = db.query(sql, unpack(where_values))

    -- Count query
    local count_sql = string.format([[
        SELECT COUNT(*) as total FROM kanban_projects WHERE %s
    ]], where_sql)

    -- Remove limit/offset from count values
    local count_values = {}
    for i = 1, #where_values - 2 do
        table.insert(count_values, where_values[i])
    end

    local count_result = db.query(count_sql, unpack(count_values))
    local total = count_result and count_result[1] and count_result[1].total or 0

    return {
        data = projects,
        total = tonumber(total)
    }
end

--- Get projects for a user (projects they are a member of)
-- @param user_uuid string User UUID
-- @param namespace_id number Namespace ID
-- @param params table Pagination parameters
-- @return table { data, total }
function KanbanProjectQueries.getByUser(user_uuid, namespace_id, params)
    params = params or {}
    local page = params.page or 1
    local perPage = params.perPage or 20
    local offset = (page - 1) * perPage

    local sql = [[
        SELECT p.*,
               pm.role as member_role,
               pm.is_starred,
               (SELECT COUNT(*) FROM kanban_project_members WHERE project_id = p.id AND left_at IS NULL) as member_count,
               (SELECT COUNT(*) FROM kanban_tasks t
                JOIN kanban_boards b ON b.id = t.board_id
                WHERE b.project_id = p.id AND t.archived_at IS NULL) as task_count
        FROM kanban_projects p
        INNER JOIN kanban_project_members pm ON pm.project_id = p.id
        WHERE pm.user_uuid = ?
          AND pm.left_at IS NULL
          AND p.namespace_id = ?
          AND p.status != 'archived'
        ORDER BY pm.is_starred DESC, p.updated_at DESC NULLS LAST
        LIMIT ? OFFSET ?
    ]]

    local projects = db.query(sql, user_uuid, namespace_id, perPage, offset)

    local count_sql = [[
        SELECT COUNT(*) as total
        FROM kanban_projects p
        INNER JOIN kanban_project_members pm ON pm.project_id = p.id
        WHERE pm.user_uuid = ? AND pm.left_at IS NULL AND p.namespace_id = ? AND p.status != 'archived'
    ]]
    local count_result = db.query(count_sql, user_uuid, namespace_id)
    local total = count_result and count_result[1] and count_result[1].total or 0

    return {
        data = projects,
        total = tonumber(total)
    }
end

--- Get single project by UUID with details
-- @param uuid string Project UUID
-- @param user_uuid string Optional user UUID to get membership info
-- @return table|nil Project with details
function KanbanProjectQueries.show(uuid, user_uuid)
    local sql = [[
        SELECT p.*,
               n.name as namespace_name,
               n.slug as namespace_slug,
               (SELECT COUNT(*) FROM kanban_project_members WHERE project_id = p.id AND left_at IS NULL) as member_count,
               (SELECT COUNT(*) FROM kanban_boards WHERE project_id = p.id AND archived_at IS NULL) as board_count
        FROM kanban_projects p
        LEFT JOIN namespaces n ON n.id = p.namespace_id
        WHERE p.uuid = ?
    ]]

    local result = db.query(sql, uuid)
    if not result or #result == 0 then
        return nil
    end

    local project = result[1]

    -- Get user's membership if user_uuid provided
    if user_uuid then
        local member_sql = [[
            SELECT role, is_starred, notification_preference
            FROM kanban_project_members
            WHERE project_id = ? AND user_uuid = ? AND left_at IS NULL
        ]]
        local member_result = db.query(member_sql, project.id, user_uuid)
        if member_result and #member_result > 0 then
            project.current_user_role = member_result[1].role
            project.is_starred = member_result[1].is_starred
            project.notification_preference = member_result[1].notification_preference
        end
    end

    return project
end

--- Get project by ID
-- @param id number Project ID
-- @return table|nil Project
function KanbanProjectQueries.getById(id)
    return KanbanProjectModel:find({ id = id })
end

--- Update project
-- @param uuid string Project UUID
-- @param params table Update parameters
-- @return table|nil Updated project
function KanbanProjectQueries.update(uuid, params)
    local project = KanbanProjectModel:find({ uuid = uuid })
    if not project then return nil end

    params.updated_at = db.raw("NOW()")

    -- Regenerate slug if name changed
    if params.name and params.name ~= project.name then
        params.slug = params.name:lower():gsub("%s+", "-"):gsub("[^%w%-]", "")
    end

    return project:update(params, { returning = "*" })
end

--- Archive project (soft delete)
-- @param uuid string Project UUID
-- @return table|nil Archived project
function KanbanProjectQueries.archive(uuid)
    local project = KanbanProjectModel:find({ uuid = uuid })
    if not project then return nil end

    return project:update({
        status = "archived",
        archived_at = db.raw("NOW()"),
        updated_at = db.raw("NOW()")
    }, { returning = "*" })
end

--- Delete project (hard delete)
-- @param uuid string Project UUID
-- @return boolean Success
function KanbanProjectQueries.destroy(uuid)
    local project = KanbanProjectModel:find({ uuid = uuid })
    if not project then return false end
    return project:delete()
end

--------------------------------------------------------------------------------
-- Project Member Operations
--------------------------------------------------------------------------------

--- Check if user is a member of project
-- @param project_id number Project ID
-- @param user_uuid string User UUID
-- @return boolean
function KanbanProjectQueries.isMember(project_id, user_uuid)
    local sql = [[
        SELECT COUNT(*) as count
        FROM kanban_project_members
        WHERE project_id = ? AND user_uuid = ? AND left_at IS NULL
    ]]
    local result = db.query(sql, project_id, user_uuid)
    return result and result[1] and tonumber(result[1].count) > 0
end

--- Check if user has admin permissions on project
-- @param project_id number Project ID
-- @param user_uuid string User UUID
-- @return boolean
function KanbanProjectQueries.isAdmin(project_id, user_uuid)
    local sql = [[
        SELECT COUNT(*) as count
        FROM kanban_project_members
        WHERE project_id = ? AND user_uuid = ? AND left_at IS NULL
          AND role IN ('owner', 'admin')
    ]]
    local result = db.query(sql, project_id, user_uuid)
    return result and result[1] and tonumber(result[1].count) > 0
end

--- Check if user is owner of project
-- @param project_id number Project ID
-- @param user_uuid string User UUID
-- @return boolean
function KanbanProjectQueries.isOwner(project_id, user_uuid)
    local sql = [[
        SELECT COUNT(*) as count
        FROM kanban_project_members
        WHERE project_id = ? AND user_uuid = ? AND left_at IS NULL AND role = 'owner'
    ]]
    local result = db.query(sql, project_id, user_uuid)
    return result and result[1] and tonumber(result[1].count) > 0
end

--- Get project members
-- @param project_id number Project ID
-- @param params table Pagination parameters
-- @return table { data, total }
function KanbanProjectQueries.getMembers(project_id, params)
    params = params or {}
    local page = params.page or 1
    local perPage = params.perPage or 50
    local offset = (page - 1) * perPage

    local sql = [[
        SELECT pm.*,
               u.email, u.first_name, u.last_name, u.username
        FROM kanban_project_members pm
        INNER JOIN users u ON u.uuid = pm.user_uuid
        WHERE pm.project_id = ? AND pm.left_at IS NULL
        ORDER BY
            CASE pm.role
                WHEN 'owner' THEN 1
                WHEN 'admin' THEN 2
                WHEN 'member' THEN 3
                WHEN 'viewer' THEN 4
                ELSE 5
            END,
            pm.joined_at ASC
        LIMIT ? OFFSET ?
    ]]

    local members = db.query(sql, project_id, perPage, offset)

    local count_sql = [[
        SELECT COUNT(*) as total
        FROM kanban_project_members
        WHERE project_id = ? AND left_at IS NULL
    ]]
    local count_result = db.query(count_sql, project_id)
    local total = count_result and count_result[1] and count_result[1].total or 0

    return {
        data = members,
        total = tonumber(total)
    }
end

--- Add member to project
-- @param project_id number Project ID
-- @param user_uuid string User UUID
-- @param role string Member role (default: "member")
-- @param invited_by string UUID of user who invited
-- @return table|nil Created member
function KanbanProjectQueries.addMember(project_id, user_uuid, role, invited_by)
    -- Check if already a member
    local existing = db.query([[
        SELECT id FROM kanban_project_members
        WHERE project_id = ? AND user_uuid = ? AND left_at IS NULL
    ]], project_id, user_uuid)

    if existing and #existing > 0 then
        return nil, "User is already a member"
    end

    return KanbanProjectMemberModel:create({
        uuid = Global.generateUUID(),
        project_id = project_id,
        user_uuid = user_uuid,
        role = role or "member",
        invited_by = invited_by,
        joined_at = db.raw("NOW()"),
        created_at = db.raw("NOW()"),
        updated_at = db.raw("NOW()")
    }, { returning = "*" })
end

--- Remove member from project
-- @param project_id number Project ID
-- @param user_uuid string User UUID
-- @return boolean Success
function KanbanProjectQueries.removeMember(project_id, user_uuid)
    local member = KanbanProjectMemberModel:find({
        project_id = project_id,
        user_uuid = user_uuid
    })

    if not member or member.left_at then
        return false, "Member not found"
    end

    -- Can't remove the owner
    if member.role == "owner" then
        return false, "Cannot remove project owner"
    end

    member:update({
        left_at = db.raw("NOW()"),
        updated_at = db.raw("NOW()")
    })

    return true
end

--- Update member role
-- @param project_id number Project ID
-- @param user_uuid string User UUID
-- @param new_role string New role
-- @return table|nil Updated member
function KanbanProjectQueries.updateMemberRole(project_id, user_uuid, new_role)
    local member = KanbanProjectMemberModel:find({
        project_id = project_id,
        user_uuid = user_uuid
    })

    if not member or member.left_at then
        return nil, "Member not found"
    end

    -- Can't change owner's role
    if member.role == "owner" then
        return nil, "Cannot change owner's role"
    end

    return member:update({
        role = new_role,
        updated_at = db.raw("NOW()")
    }, { returning = "*" })
end

--- Toggle starred status for member
-- @param project_id number Project ID
-- @param user_uuid string User UUID
-- @return table|nil Updated member
function KanbanProjectQueries.toggleStarred(project_id, user_uuid)
    local member = KanbanProjectMemberModel:find({
        project_id = project_id,
        user_uuid = user_uuid
    })

    if not member or member.left_at then
        return nil, "Not a member of this project"
    end

    return member:update({
        is_starred = not member.is_starred,
        updated_at = db.raw("NOW()")
    }, { returning = "*" })
end

--------------------------------------------------------------------------------
-- Statistics
--------------------------------------------------------------------------------

--- Get project statistics
-- @param project_id number Project ID
-- @return table Statistics
function KanbanProjectQueries.getStats(project_id)
    local sql = [[
        SELECT
            p.task_count,
            p.completed_task_count,
            (SELECT COUNT(*) FROM kanban_project_members WHERE project_id = p.id AND left_at IS NULL) as member_count,
            (SELECT COUNT(*) FROM kanban_boards WHERE project_id = p.id AND archived_at IS NULL) as board_count,
            (SELECT COUNT(*) FROM kanban_tasks t
             JOIN kanban_boards b ON b.id = t.board_id
             WHERE b.project_id = p.id AND t.status = 'in_progress') as in_progress_count,
            (SELECT COUNT(*) FROM kanban_tasks t
             JOIN kanban_boards b ON b.id = t.board_id
             WHERE b.project_id = p.id AND t.due_date < CURRENT_DATE AND t.status NOT IN ('completed', 'cancelled')) as overdue_count
        FROM kanban_projects p
        WHERE p.id = ?
    ]]

    local result = db.query(sql, project_id)
    if result and #result > 0 then
        local stats = result[1]
        -- Calculate progress percentage
        if stats.task_count and tonumber(stats.task_count) > 0 then
            stats.progress_percentage = math.floor((tonumber(stats.completed_task_count) / tonumber(stats.task_count)) * 100)
        else
            stats.progress_percentage = 0
        end
        return stats
    end

    return {
        task_count = 0,
        completed_task_count = 0,
        member_count = 0,
        board_count = 0,
        in_progress_count = 0,
        overdue_count = 0,
        progress_percentage = 0
    }
end

return KanbanProjectQueries
