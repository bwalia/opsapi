-- Next actions: a property_deals task (a kanban task underneath) with the reason it exists and the interaction it
-- came from. One owner, a due time and a reason, always (build prompt: "every action has an owner and a why").
local db = require("lapis.db")
local U = require("property_deals.util")

local A = {}

--- value = { title, due_at, reason, owner_user_uuid?, opportunity_uuid?, lead_uuid?, property_uuid?, priority? }
-- @return the task (property_deals Tasks.get shape + reason)
function A.create(ns, value, actor_uuid, _settings, source_interaction_uuid)
    local errors = {}
    if type(value.title) ~= "string" or value.title == "" then errors.title = "is required" end
    if type(value.reason) ~= "string" or value.reason == "" then errors.reason = "every next action needs a reason" end
    if type(value.due_at) ~= "string" or not value.due_at:match("^%d%d%d%d%-%d%d%-%d%d") then
        errors.due_at = "is required (ISO date-time)"
    end
    if value.opportunity_uuid ~= nil and not U.is_uuid(value.opportunity_uuid) then errors.opportunity_uuid = "must be a uuid" end
    if next(errors) then U.fail(422, "Validation failed", errors) end
    local opp
    if value.opportunity_uuid then
        opp = U.one([[SELECT uuid, owner_user_uuid, lead_uuid, property_uuid FROM pa_opportunities
            WHERE namespace_id = ? AND uuid = ?::uuid]], ns, value.opportunity_uuid)
        if not opp then U.fail(422, "Validation failed", { opportunity_uuid = "not found in this workspace" }) end
    end
    local owner = value.owner_user_uuid or (opp and opp.owner_user_uuid ~= db.NULL and opp.owner_user_uuid) or actor_uuid
    require("property_deals.workspace").ensure(ns, actor_uuid, require("helper.plugin-sdk").settings("property_deals", ns))
    local Tasks = require("property_deals.tasks")
    local task = Tasks.create(ns, {
        title = value.title:sub(1, 255), description = value.reason, priority = value.priority,
        due_at = value.due_at, owner_user_uuid = owner,
        lead_uuid = value.lead_uuid or (opp and opp.lead_uuid ~= db.NULL and opp.lead_uuid) or nil,
        property_uuid = value.property_uuid or (opp and opp.property_uuid ~= db.NULL and opp.property_uuid) or nil,
    }, actor_uuid)
    db.update("property_deals_task_details", {
        reason = value.reason, opportunity_uuid = opp and opp.uuid or db.NULL,
        created_from_interaction_uuid = source_interaction_uuid or db.NULL,
    }, { namespace_id = ns, task_uuid = task.task_uuid })
    return A.get(ns, task.task_uuid)
end

function A.get(ns, task_uuid)
    return U.one([[
        SELECT d.task_uuid, t.title, d.reason, d.pd_status, d.due_at, d.owner_user_uuid, d.opportunity_uuid,
               d.lead_uuid, d.property_uuid, d.created_from_interaction_uuid, d.urgency_score, d.created_at
        FROM property_deals_task_details d JOIN kanban_tasks t ON t.uuid = d.task_uuid
        WHERE d.namespace_id = ? AND d.task_uuid = ?
    ]], ns, task_uuid)
end

--- Open next actions for an opportunity (or mine when owner given), soonest first.
function A.open(ns, params)
    local where = { "d.namespace_id = " .. db.escape_literal(ns), "d.pd_status NOT IN ('done', 'cancelled')" }
    if U.is_uuid(params.opportunity_uuid) then
        where[#where + 1] = "d.opportunity_uuid = " .. db.escape_literal(params.opportunity_uuid) .. "::uuid"
    else
        where[#where + 1] = "d.opportunity_uuid IS NOT NULL"
    end
    if params.owner_user_uuid then where[#where + 1] = "d.owner_user_uuid = " .. db.escape_literal(params.owner_user_uuid) end
    return U.array(db.query([[
        SELECT d.task_uuid, t.title, d.reason, d.pd_status, d.due_at, (d.due_at < NOW()) AS overdue, d.owner_user_uuid,
               d.opportunity_uuid, d.created_from_interaction_uuid
        FROM property_deals_task_details d JOIN kanban_tasks t ON t.uuid = d.task_uuid
        WHERE ]] .. table.concat(where, " AND ") .. " ORDER BY d.due_at ASC NULLS LAST LIMIT 100"))
end

return A
