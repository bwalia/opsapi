--[[
    Kanban Epic Queries
    ===================

    Epics are a project-level container that groups tasks (Jira-style), one
    level above tasks: epic -> task. Subtasks (kanban_tasks.parent_task_id)
    are untouched and stay beneath tasks.

    Epics live in their own table rather than as a row type inside
    kanban_tasks so that board/list queries -- which already filter
    `parent_task_id IS NULL` -- need no extra exclusion, and a missed filter
    can never render an epic as a stray card on a board.

    Rollups (task_count / completed_task_count / total_points /
    completed_points) are computed in SQL on read. Unlike kanban_sprints
    there are no denormalised counter columns: a second write path is not
    worth it until a listing is measurably slow.

    Every query is namespace-scoped. Middleware resolves the tenant; it does
    not filter SQL for you.
]]

local KanbanEpicModel = require "models.KanbanEpicModel"
local Global = require "helper.global"
local db = require("lapis.db")

local KanbanEpicQueries = {}

local VALID_STATUSES = {
    open = true,
    in_progress = true,
    done = true,
    cancelled = true
}

--- Normalise a client-supplied epic_id to a real id or nil.
-- The wire format sends "" for "no epic" and some clients send 0; both would
-- violate kanban_tasks_epic_fk. Mirrors the sprint_id/parent_task_id
-- normalisation in KanbanTaskQueries.create.
-- @param value any Raw epic_id from a request body
-- @return number|nil Epic ID or nil
function KanbanEpicQueries.normaliseEpicId(value)
    if value == nil or value == "" or value == 0 or value == "0" then
        return nil
    end
    return tonumber(value) or nil
end

-- Rollup aggregate shared by getByProject / show. Counts only live,
-- unarchived tasks.
local ROLLUP_SELECT = [[
    SELECT epic_id,
           COUNT(*) AS task_count,
           COUNT(*) FILTER (WHERE status = 'completed') AS completed_task_count,
           COALESCE(SUM(story_points), 0) AS total_points,
           COALESCE(SUM(story_points) FILTER (WHERE status = 'completed'), 0) AS completed_points
    FROM kanban_tasks
    WHERE epic_id IS NOT NULL AND deleted_at IS NULL AND archived_at IS NULL
    GROUP BY epic_id
]]

--- Coerce the aggregate columns on a row to numbers (pgmoon returns strings
--- for COUNT/SUM) and default them when an epic has no tasks yet.
-- @param row table Epic row
-- @return table The same row, with numeric rollups
local function normalise_rollups(row)
    row.task_count = tonumber(row.task_count) or 0
    row.completed_task_count = tonumber(row.completed_task_count) or 0
    row.total_points = tonumber(row.total_points) or 0
    row.completed_points = tonumber(row.completed_points) or 0
    row.progress = row.total_points > 0
        and math.floor((row.completed_points / row.total_points) * 100)
        or (row.task_count > 0
            and math.floor((row.completed_task_count / row.task_count) * 100)
            or 0)
    return row
end

--------------------------------------------------------------------------------
-- Epic CRUD Operations
--------------------------------------------------------------------------------

--- Create a new epic
-- @param params table { project_id, namespace_id, name, description, status,
--                       color, start_date, due_date, created_by }
-- @return table|nil Created epic, or nil + error message
function KanbanEpicQueries.create(params)
    if not params.project_id or not params.namespace_id then
        return nil, "project_id and namespace_id are required"
    end

    if not params.name or params.name == "" then
        return nil, "name is required"
    end

    -- Validate the project exists AND belongs to the caller's namespace.
    local project = db.query([[
        SELECT id FROM kanban_projects WHERE id = ? AND namespace_id = ?
    ]], params.project_id, params.namespace_id)
    if not project or #project == 0 then
        return nil, "Project not found"
    end

    if params.status and not VALID_STATUSES[params.status] then
        return nil, "Invalid status. Must be: open, in_progress, done, or cancelled"
    end

    local insert = {
        uuid = params.uuid or Global.generateUUID(),
        project_id = params.project_id,
        namespace_id = params.namespace_id,
        name = params.name,
        description = params.description,
        status = params.status or "open",
        color = params.color,
        start_date = params.start_date,
        due_date = params.due_date,
        created_by = params.created_by,
        created_at = db.raw("NOW()"),
        updated_at = db.raw("NOW()")
    }

    -- Drop nils so Postgres applies its own column defaults.
    local clean = {}
    for k, v in pairs(insert) do
        if v ~= nil and v ~= "" then
            clean[k] = v
        end
    end

    local epic = KanbanEpicModel:create(clean, { returning = "*" })

    if epic then
        ngx.log(ngx.INFO, "[Epic] Created: ", epic.uuid, " for project: ", params.project_id)
    end

    return epic
end

--- Get epics for a project, with rollups
-- @param project_id number Project ID
-- @param namespace_id number Namespace ID (tenant scope)
-- @param params table { page, perPage, status }
-- @return table { data, total }
function KanbanEpicQueries.getByProject(project_id, namespace_id, params)
    params = params or {}
    local page = params.page or 1
    local perPage = params.perPage or 20
    local offset = (page - 1) * perPage

    local where_clauses = { "e.project_id = ?", "e.namespace_id = ?", "e.deleted_at IS NULL" }
    local where_values = { project_id, namespace_id }

    if params.status then
        table.insert(where_clauses, "e.status = ?")
        table.insert(where_values, params.status)
    end

    local where_sql = table.concat(where_clauses, " AND ")

    local sql = string.format([[
        SELECT e.*,
               COALESCE(r.task_count, 0) AS task_count,
               COALESCE(r.completed_task_count, 0) AS completed_task_count,
               COALESCE(r.total_points, 0) AS total_points,
               COALESCE(r.completed_points, 0) AS completed_points
        FROM kanban_epics e
        LEFT JOIN (%s) r ON r.epic_id = e.id
        WHERE %s
        ORDER BY
            CASE e.status
                WHEN 'in_progress' THEN 1
                WHEN 'open' THEN 2
                WHEN 'done' THEN 3
                ELSE 4
            END,
            e.due_date ASC NULLS LAST,
            e.created_at DESC
        LIMIT ? OFFSET ?
    ]], ROLLUP_SELECT, where_sql)

    local query_values = {}
    for _, v in ipairs(where_values) do table.insert(query_values, v) end
    table.insert(query_values, perPage)
    table.insert(query_values, offset)

    local epics = db.query(sql, table.unpack(query_values)) or {}
    for _, epic in ipairs(epics) do
        normalise_rollups(epic)
    end

    local count_sql = string.format("SELECT COUNT(*) AS total FROM kanban_epics e WHERE %s", where_sql)
    local count_result = db.query(count_sql, table.unpack(where_values))
    local total = count_result and count_result[1] and count_result[1].total or 0

    return {
        data = epics,
        total = tonumber(total)
    }
end

--- Get a single epic by UUID, with rollups
-- @param uuid string Epic UUID
-- @param namespace_id number|nil Namespace ID (tenant scope; omit only for
--                                internal callers that scope another way)
-- @return table|nil Epic
function KanbanEpicQueries.show(uuid, namespace_id)
    local sql = string.format([[
        SELECT e.*,
               p.name AS project_name,
               p.uuid AS project_uuid,
               COALESCE(r.task_count, 0) AS task_count,
               COALESCE(r.completed_task_count, 0) AS completed_task_count,
               COALESCE(r.total_points, 0) AS total_points,
               COALESCE(r.completed_points, 0) AS completed_points
        FROM kanban_epics e
        INNER JOIN kanban_projects p ON p.id = e.project_id
        LEFT JOIN (%s) r ON r.epic_id = e.id
        WHERE e.uuid = ? AND e.deleted_at IS NULL
    ]], ROLLUP_SELECT)

    local values = { uuid }
    if namespace_id then
        sql = sql .. " AND e.namespace_id = ?"
        table.insert(values, namespace_id)
    end

    local result = db.query(sql, table.unpack(values))
    if not result or #result == 0 then
        return nil
    end

    return normalise_rollups(result[1])
end

--- Get epic by ID
-- @param id number Epic ID
-- @return table|nil Epic
function KanbanEpicQueries.getById(id)
    return KanbanEpicModel:find({ id = id })
end

--- Update an epic
-- @param uuid string Epic UUID
-- @param namespace_id number Namespace ID (tenant scope)
-- @param params table Update parameters
-- @return table|nil Updated epic, or nil + error message
function KanbanEpicQueries.update(uuid, namespace_id, params)
    local epic = KanbanEpicModel:find({ uuid = uuid })
    if not epic or epic.deleted_at then
        return nil, "Epic not found"
    end

    if tonumber(epic.namespace_id) ~= tonumber(namespace_id) then
        return nil, "Epic not found"
    end

    if params.status and not VALID_STATUSES[params.status] then
        return nil, "Invalid status. Must be: open, in_progress, done, or cancelled"
    end

    params.updated_at = db.raw("NOW()")
    epic:update(params, { returning = "*" })

    -- :update() returns a boolean; the refreshed row was merged into `epic`.
    return KanbanEpicQueries.show(uuid, namespace_id) or epic
end

--- Soft-delete an epic. Tasks are detached (epic_id -> NULL) rather than
--- deleted; the FK is ON DELETE SET NULL, but this keeps rollups honest for
--- a soft delete too.
-- @param uuid string Epic UUID
-- @param namespace_id number Namespace ID (tenant scope)
-- @return boolean Success, or false + error message
function KanbanEpicQueries.destroy(uuid, namespace_id)
    local epic = KanbanEpicModel:find({ uuid = uuid })
    if not epic or epic.deleted_at then
        return false, "Epic not found"
    end

    if tonumber(epic.namespace_id) ~= tonumber(namespace_id) then
        return false, "Epic not found"
    end

    db.query([[
        UPDATE kanban_tasks SET epic_id = NULL, updated_at = NOW()
        WHERE epic_id = ? AND deleted_at IS NULL
    ]], epic.id)

    epic:update({
        deleted_at = db.raw("NOW()"),
        updated_at = db.raw("NOW()")
    })

    ngx.log(ngx.INFO, "[Epic] Deleted: ", uuid)

    return true
end

--------------------------------------------------------------------------------
-- Task-Epic Operations
--------------------------------------------------------------------------------

--- Get the tasks in an epic
-- @param epic_id number Epic ID
-- @param params table { page, perPage }
-- @return table { data, total }
function KanbanEpicQueries.getTasks(epic_id, params)
    params = params or {}
    local page = params.page or 1
    local perPage = params.perPage or 50
    local offset = (page - 1) * perPage

    local tasks = db.query([[
        SELECT t.*,
               c.name AS column_name,
               c.color AS column_color,
               b.name AS board_name,
               b.uuid AS board_uuid
        FROM kanban_tasks t
        LEFT JOIN kanban_columns c ON c.id = t.column_id
        LEFT JOIN kanban_boards b ON b.id = t.board_id
        WHERE t.epic_id = ? AND t.deleted_at IS NULL AND t.archived_at IS NULL
        ORDER BY t.priority DESC, t.position ASC
        LIMIT ? OFFSET ?
    ]], epic_id, perPage, offset) or {}

    local count_result = db.query([[
        SELECT COUNT(*) AS total FROM kanban_tasks
        WHERE epic_id = ? AND deleted_at IS NULL AND archived_at IS NULL
    ]], epic_id)
    local total = count_result and count_result[1] and count_result[1].total or 0

    return {
        data = tasks,
        total = tonumber(total)
    }
end

--- Attach tasks to an epic.
-- Only tasks whose board belongs to the epic's project (and namespace) are
-- moved, so a task can never be pulled across a tenant boundary.
-- @param epic table Epic row (needs id + project_id + namespace_id)
-- @param task_uuids table[] Task UUIDs
-- @return number Count of attached tasks
function KanbanEpicQueries.assignTasks(epic, task_uuids)
    if not task_uuids or #task_uuids == 0 then
        return 0
    end

    local count = 0
    for _, task_uuid in ipairs(task_uuids) do
        if type(task_uuid) == "string" and task_uuid ~= "" then
            local result = db.query([[
                UPDATE kanban_tasks t
                SET epic_id = ?, updated_at = NOW()
                FROM kanban_boards b
                INNER JOIN kanban_projects p ON p.id = b.project_id
                WHERE t.board_id = b.id
                  AND t.uuid = ?
                  AND t.deleted_at IS NULL
                  AND t.archived_at IS NULL
                  AND p.id = ?
                  AND p.namespace_id = ?
            ]], epic.id, task_uuid, epic.project_id, epic.namespace_id)

            if result and result.affected_rows and result.affected_rows > 0 then
                count = count + 1
            end
        end
    end

    return count
end

--- Detach tasks from an epic
-- @param epic table Epic row (needs id)
-- @param task_uuids table[] Task UUIDs
-- @return number Count of detached tasks
function KanbanEpicQueries.unassignTasks(epic, task_uuids)
    if not task_uuids or #task_uuids == 0 then
        return 0
    end

    local count = 0
    for _, task_uuid in ipairs(task_uuids) do
        if type(task_uuid) == "string" and task_uuid ~= "" then
            local result = db.query([[
                UPDATE kanban_tasks
                SET epic_id = NULL, updated_at = NOW()
                WHERE uuid = ? AND epic_id = ? AND deleted_at IS NULL
            ]], task_uuid, epic.id)

            if result and result.affected_rows and result.affected_rows > 0 then
                count = count + 1
            end
        end
    end

    return count
end

return KanbanEpicQueries
