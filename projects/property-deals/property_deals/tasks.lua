-- Deal tasks: a kanban task (so it shows on boards, My Tasks and the iOS app)
-- plus a property_deals_task_details row with SLA, urgency and agent fields.
-- pd_status is exact; the kanban status/column follow it (gap map §2.6).
local db = require("lapis.db")
local U = require("property_deals.util")

local Tasks = {}

Tasks.STATUSES = { "todo", "in_progress", "waiting_third_party", "agent_running", "awaiting_approval", "done", "cancelled" }
Tasks.OPEN = { todo = true, in_progress = true, waiting_third_party = true, agent_running = true, awaiting_approval = true }

-- pd_status -> kanban status + default board column name.
local KANBAN = {
    todo = { "open", "To Do" },
    in_progress = { "in_progress", "In Progress" },
    waiting_third_party = { "blocked", "In Progress" },
    agent_running = { "in_progress", "In Progress" },
    awaiting_approval = { "review", "Review" },
    done = { "completed", "Done" },
    cancelled = { "cancelled", "Done" },
}

local PRIORITY = { critical = "critical", high = "high", medium = "medium", low = "low" }

local function column_id(board_id, pd_status)
    local name = KANBAN[pd_status][2]
    local col = U.one("SELECT id FROM kanban_columns WHERE board_id = ? AND name = ? LIMIT 1", board_id, name)
    if not col then
        col = U.one("SELECT id FROM kanban_columns WHERE board_id = ? ORDER BY position LIMIT 1", board_id)
    end
    return col and col.id
end

local function board_for(ns)
    local state = U.one([[
        SELECT b.id, b.uuid FROM property_deals_workspaces w
        JOIN kanban_boards b ON b.uuid = w.kanban_board_uuid
        WHERE w.namespace_id = ?
    ]], ns)
    if not state then U.fail(409, "Property Deals isn't set up in this workspace yet (POST /setup)") end
    return state
end

--- Create a task. t = { title, description?, priority?, deal (row)?, stage_key?, template_key?,
-- due_at?, sla_minutes?, blocking?, compliance?, agent_eligible?, agent_key?, approval_rule?,
-- owner_user_uuid?, owner_agent_key?, property_uuid?, lead_uuid?, pd_status? }
-- @return details row joined with the kanban task's title/description
function Tasks.create(ns, t, actor_uuid)
    local board = board_for(ns)
    local status = t.pd_status or "todo"
    local epic_id
    if t.deal and t.deal.kanban_epic_uuid then
        local epic = U.one("SELECT id FROM kanban_epics WHERE uuid = ? AND namespace_id = ?", t.deal.kanban_epic_uuid, ns)
        epic_id = epic and epic.id
    end
    local task = require("queries.KanbanTaskQueries").create({
        board_id = board.id,
        column_id = column_id(board.id, status),
        epic_id = epic_id,
        title = t.title,
        description = t.description,
        status = KANBAN[status][1],
        priority = PRIORITY[t.priority] or "medium",
        due_date = t.due_at and db.raw("(" .. db.escape_literal(t.due_at) .. "::timestamptz)::date") or nil,
        reporter_user_uuid = actor_uuid,
    })
    if t.owner_user_uuid then
        require("queries.KanbanTaskQueries").assignUser(task.id, t.owner_user_uuid, actor_uuid, ns)
    end
    local details = db.insert("property_deals_task_details", {
        namespace_id = ns,
        task_uuid = task.uuid,
        deal_uuid = t.deal and t.deal.uuid or nil,
        property_uuid = t.property_uuid or (t.deal and t.deal.property_uuid) or nil,
        lead_uuid = t.lead_uuid,
        template_key = t.template_key,
        stage_key = t.stage_key,
        pd_status = status,
        owner_user_uuid = t.owner_user_uuid,
        owner_agent_key = t.owner_agent_key,
        due_at = t.due_at,
        sla_minutes = t.sla_minutes,
        sla_started_at = t.sla_minutes and db.raw("NOW()") or nil,
        blocking = t.blocking == true,
        compliance = t.compliance == true,
        agent_eligible = t.agent_eligible == true,
        agent_key = t.agent_key,
        approval_rule = t.approval_rule or "any_operator",
        metadata = t.metadata and require("cjson").encode(t.metadata) or nil,
    }, { returning = "*" })[1]
    return Tasks.get(ns, details.task_uuid)
end

local SELECT = [[
    SELECT d.*, t.title, t.description, t.priority, t.task_number, t.status AS kanban_status,
           t.comment_count, t.attachment_count, dl.crm_deal_uuid, cd.name AS deal_name
    FROM property_deals_task_details d
    JOIN kanban_tasks t ON t.uuid = d.task_uuid
    LEFT JOIN property_deals_deals dl ON dl.uuid = d.deal_uuid
    LEFT JOIN crm_deals cd ON cd.uuid = dl.crm_deal_uuid
]]

function Tasks.get(ns, task_uuid)
    return U.one(SELECT .. " WHERE d.namespace_id = ? AND d.task_uuid = ?", ns, task_uuid)
end

--- List with filters: deal_uuid, pd_status (comma list), owner_user_uuid, open=true, blocking, compliance.
function Tasks.list(ns, params)
    local where = { "d.namespace_id = " .. db.escape_literal(ns) }
    if U.is_uuid(params.deal_uuid) then where[#where + 1] = "d.deal_uuid = " .. db.escape_literal(params.deal_uuid) end
    if params.owner_user_uuid and params.owner_user_uuid ~= "" then
        where[#where + 1] = "d.owner_user_uuid = " .. db.escape_literal(params.owner_user_uuid)
    end
    if params.pd_status and params.pd_status ~= "" then
        local list = {}
        for s in tostring(params.pd_status):gmatch("[%w_]+") do list[#list + 1] = db.escape_literal(s) end
        if #list > 0 then where[#where + 1] = "d.pd_status IN (" .. table.concat(list, ", ") .. ")" end
    end
    if params.open == "true" then where[#where + 1] = "d.pd_status NOT IN ('done', 'cancelled')" end
    if params.blocking == "true" then where[#where + 1] = "d.blocking" end
    if params.compliance == "true" then where[#where + 1] = "d.compliance" end
    local order = ({
        urgency = "d.urgency_score DESC, d.due_at ASC NULLS LAST",
        due = "d.due_at ASC NULLS LAST",
        created = "d.created_at DESC",
    })[params.sort or "urgency"] or "d.urgency_score DESC, d.due_at ASC NULLS LAST"
    local page, per_page, offset = require("helper.plugin-sdk").page(params)
    local w = table.concat(where, " AND ")
    local rows = db.query(SELECT .. " WHERE " .. w .. " ORDER BY " .. order .. ", d.id DESC LIMIT "
        .. per_page .. " OFFSET " .. offset)
    local total = db.query("SELECT COUNT(*)::int AS n FROM property_deals_task_details d WHERE " .. w)[1].n
    return U.array(rows), { page = page, per_page = per_page, total = total, total_pages = math.ceil(total / per_page) }
end

--- Apply a change to a task's details and keep the kanban task in step.
-- `changes` are validated columns of property_deals_task_details plus
-- title/description/priority for the kanban task.
function Tasks.update(ns, task_uuid, changes, actor_uuid)
    local current = Tasks.get(ns, task_uuid)
    if not current then return nil end
    local kanban = {}
    for _, k in ipairs({ "title", "description", "priority" }) do
        if changes[k] ~= nil then kanban[k], changes[k] = changes[k], nil end
    end
    local status = changes.pd_status
    if status and status ~= current.pd_status then
        local board = board_for(ns)
        kanban.status = KANBAN[status][1]
        kanban.column_id = column_id(board.id, status)
        if status == "done" then
            changes.completed_at = db.raw("NOW()")
            changes.completed_by_user_uuid = actor_uuid
            kanban.completed_at = db.raw("NOW()")
        elseif current.pd_status == "done" then
            changes.completed_at = db.NULL
            changes.completed_by_user_uuid = db.NULL
            kanban.completed_at = db.NULL
        end
    end
    if changes.due_at ~= nil then
        kanban.due_date = changes.due_at == db.NULL and db.NULL
            or db.raw("(" .. db.escape_literal(changes.due_at) .. "::timestamptz)::date")
    end
    if next(kanban) then
        kanban.updated_at = db.raw("NOW()")
        db.update("kanban_tasks", kanban, { uuid = task_uuid })
    end
    if changes.owner_user_uuid and changes.owner_user_uuid ~= db.NULL and changes.owner_user_uuid ~= current.owner_user_uuid then
        local t = U.one("SELECT id FROM kanban_tasks WHERE uuid = ?", task_uuid)
        require("queries.KanbanTaskQueries").assignUser(t.id, changes.owner_user_uuid, actor_uuid, ns)
    end
    if next(changes) then
        changes.updated_at = db.raw("NOW()")
        db.update("property_deals_task_details", changes, { namespace_id = ns, task_uuid = task_uuid })
    end
    return Tasks.get(ns, task_uuid)
end

return Tasks
