-- Deal tasks: /api/v2/property-deals/tasks. Each is a kanban task + details.
--   GET    /tasks               list ?deal_uuid=&pd_status=a,b&owner_user_uuid=&open=true&blocking=true&compliance=true&sort=urgency|due|created
--   GET    /tasks/:id           one task (id = kanban task uuid)
--   POST   /tasks               ad-hoc task on a deal (workflow tasks are created by the engine)
--   PUT    /tasks/:id           update status, owner, due time, snooze... The PA (X-OpsAPI-Agent) closes a lead's
--                                task only with evidence.chase_uuid: the call / message it just logged for that lead
--                                that did the task's work. One chase closes one task, never all of a lead's tasks.
--                                A task's approval rule covers closing it (anything it sends, books or pays): "manager"
--                                needs approvals.manage, "two_person" always goes through request-completion, and only
--                                a manager changes a task's approval rule or compliance flag. The AI service account
--                                never closes a compliance task or one with a rule.
--   POST   /tasks/:id/request-completion {note?, evidence?}   ask for the task to be closed under its rule (an
--                                approval; once approved the task is done with that evidence)
--   GET    /tasks/:id/dependencies, POST /tasks/:id/dependencies {depends_on_task_uuid}, DELETE /tasks/:id/dependencies/:dep
local root = debug.getinfo(1, "S").source:match("^@(.+)/api/[^/]+%.lua$")
if root and not package.path:find(root .. "/?.lua", 1, true) then package.path = root .. "/?.lua;" .. package.path end

local sdk = require("helper.plugin-sdk")
local db = require("lapis.db")
local U = require("property_deals.util")
local Tasks = require("property_deals.tasks")
local Deals = require("property_deals.deals")
local Workspace = require("property_deals.workspace")
local Approvals = require("property_deals.approvals")

local RULE_WHO = { any_operator = "an operator", manager = "a manager", two_person = "two people" }

--- nil when the caller may close a task with this approval rule directly, else who must sign it off.
local function close_needs(self, rule)
    if rule == "two_person" then return RULE_WHO.two_person end
    if rule == "manager" and not sdk.can(self, "property_deals_approvals", "manage") then return RULE_WHO.manager end
    if rule == "any_operator" and not sdk.can(self, "property_deals_approvals", "update") then
        return RULE_WHO.any_operator
    end
end

local function no_evidence(ev)
    return ev == nil or ev == db.NULL or ev == "{}" or (type(ev) == "table" and next(ev) == nil)
end

local EVIDENCE_NEEDED = "a compliance task needs evidence (e.g. {\"note\": ..., \"document_uuid\": ...}) to close"

local COMMON = {
    title = { type = "string" },
    description = { type = "text" },
    priority = { enum = { "critical", "high", "medium", "low" } },
    owner_user_uuid = { type = "uuid" },
    due_at = { type = "datetime" },
    sla_minutes = { type = "integer", min = 1 },
    blocking = { type = "boolean" },
    compliance = { type = "boolean" },
    agent_eligible = { type = "boolean" },
    agent_key = { type = "string", max = 80 },
    approval_rule = { enum = { "none", "any_operator", "manager", "two_person" } },
}

local CREATE = {
    deal_uuid = { type = "uuid" },
    property_uuid = { type = "uuid" },
    lead_uuid = { type = "uuid" },
    stage_key = { type = "string", max = 80 },
}
for k, v in pairs(COMMON) do CREATE[k] = v end
CREATE.title = { type = "string", required = true }

local UPDATE = {
    pd_status = { enum = Tasks.STATUSES, label = "Status" },
    snoozed_until = { type = "datetime" },
    snooze_reason = { type = "text" },
    evidence = { type = "json" },
}
for k, v in pairs(COMMON) do UPDATE[k] = v end

local function input(self, rules, partial)
    local body, err = sdk.body(self)
    if not body then return nil, sdk.error(400, err) end
    local data, errors = sdk.validate(body, rules, partial)
    if not data then return nil, sdk.error(422, "Validation failed", errors) end
    return data
end

return function(app)
    app:get("/tasks", sdk.handler({ permission = "property_deals_tasks.read" }, function(self)
        local rows, meta = Tasks.list(sdk.namespace_id(self), self.params)
        return sdk.ok(rows, meta)
    end))

    app:get("/tasks/:id", sdk.handler({ permission = "property_deals_tasks.read" }, function(self)
        local task = Tasks.get(sdk.namespace_id(self), self.params.id)
        if not task then return sdk.not_found("Task") end
        return sdk.ok(task)
    end))

    app:post("/tasks", sdk.handler({ permission = "property_deals_tasks.create" }, U.guard_create(function(self)
        local data, bad = input(self, CREATE)
        if not data then return bad end
        local ns, user = sdk.namespace_id(self), sdk.user(self).uuid
        Workspace.ensure(ns, user, sdk.settings(self))
        if data.deal_uuid then
            data.deal = Deals.get(ns, data.deal_uuid)
            if not data.deal then return sdk.error(422, "Validation failed", { deal_uuid = "not found" }) end
            data.stage_key = data.stage_key or data.deal.stage_key
        end
        local task = U.tx(function() return Tasks.create(ns, data, user) end)
        return sdk.created(task)
    end)))

    app:put("/tasks/:id", sdk.handler({ permission = "property_deals_tasks.update" }, U.guard(function(self)
        local data, bad = input(self, UPDATE, true)
        if not data then return bad end
        local ns, me = sdk.namespace_id(self), sdk.user(self).uuid
        local current = Tasks.get(ns, self.params.id)
        if not current then return sdk.not_found("Task") end
        local rule = current.approval_rule ~= db.NULL and current.approval_rule or "none"
        if (data.approval_rule ~= nil and data.approval_rule ~= rule)
            or (data.compliance ~= nil and data.compliance ~= (current.compliance == true)) then
            if not sdk.can(self, "property_deals_tasks", "manage") then
                return sdk.error(403, "Only a manager can change a task's approval rule or compliance flag")
            end
        end
        if data.pd_status and data.pd_status ~= current.pd_status then
            -- A draft or sign-off is waiting: decide it first, so the same work can't be drafted and sent twice.
            if data.pd_status ~= "cancelled" and U.one([[SELECT 1 FROM property_deals_approvals
                WHERE namespace_id = ? AND task_uuid = ? AND status = 'pending']], ns, current.task_uuid) then
                return sdk.error(409, "This task is waiting for an approval; decide it in Approvals first")
            end
        end
        if data.pd_status == "done" and current.pd_status ~= "done" then
            if (current.compliance or rule ~= "none") and Approvals.is_agent(ns, me) then
                return sdk.error(403, "An AI agent can't close this task; a person must")
            end
            local who = close_needs(self, rule)
            if who then
                return sdk.error(409, "This task needs sign-off by " .. who .. ": ask for approval instead "
                    .. "(POST /tasks/:id/request-completion)", { approval_rule = rule })
            end
            -- Hard rule 6: a compliance task is closed by a named human, with a note or evidence.
            if current.compliance and no_evidence(data.evidence or current.evidence) then
                return sdk.error(422, "Validation failed", { evidence = EVIDENCE_NEEDED })
            end
        end
        if data.snoozed_until and data.snoozed_until ~= db.NULL and not (data.snooze_reason or current.snooze_reason) then
            return sdk.error(422, "Validation failed", { snooze_reason = "is required when snoozing" })
        end
        local chase
        local lead_task = current.lead_uuid and current.lead_uuid ~= db.NULL
        if ngx.var.http_x_opsapi_agent and data.pd_status == "done" and lead_task then
            local ev = U.json(data.evidence)
            local id = type(ev) == "table" and ev.chase_uuid
            chase = U.is_uuid(id) and U.one([[
                SELECT uuid FROM property_deals_chases WHERE namespace_id = ? AND uuid = ? AND lead_uuid = ?
                  AND (task_uuid IS NULL OR task_uuid = ?)
            ]], ns, id, current.lead_uuid, current.task_uuid)
            if not chase then
                return sdk.error(422, "Validation failed", { evidence = "the assistant closes a lead's task only "
                    .. "with evidence.chase_uuid: the call or message just logged for this lead (POST /chases) that "
                    .. "did this task's work. Each one closes one task." })
            end
        end
        local task = U.tx(function()
            -- The chase now belongs to the task it completed, so it can't close another one.
            if chase then
                db.update("property_deals_chases", { task_uuid = current.task_uuid }, { uuid = chase.uuid })
            end
            if data.pd_status == "cancelled" then
                db.query([[UPDATE property_deals_approvals SET status = 'cancelled', decided_at = NOW(),
                    updated_at = NOW() WHERE namespace_id = ? AND task_uuid = ? AND status = 'pending']],
                    ns, current.task_uuid)
            end
            return Tasks.update(ns, current.task_uuid, data, me)
        end)
        if task.deal_uuid then require("property_deals.health").recompute_deal(ns, task.deal_uuid, sdk.settings(self)) end
        return sdk.ok(Tasks.get(ns, current.task_uuid))
    end)))

    app:post("/tasks/:id/request-completion", sdk.handler({ permission = "property_deals_tasks.update" },
        U.guard_create(function(self)
        local data, bad = input(self, { note = { type = "text", max = 4000 }, evidence = { type = "json" } })
        if not data then return bad end
        local ns, me = sdk.namespace_id(self), sdk.user(self).uuid
        local t = Tasks.get(ns, self.params.id)
        if not t then return sdk.not_found("Task") end
        if not Tasks.OPEN[t.pd_status] then return sdk.error(409, "The task is already " .. t.pd_status) end
        local evidence = U.json(data.evidence)
        if t.compliance and no_evidence(evidence) and not data.note then
            return sdk.error(422, "Validation failed", { evidence = EVIDENCE_NEEDED })
        end
        local rule = t.approval_rule ~= db.NULL and RULE_WHO[t.approval_rule] and t.approval_rule or "any_operator"
        local a = U.tx(function()
            local busy = U.one([[SELECT 1 FROM property_deals_approvals WHERE namespace_id = ? AND task_uuid = ?
                AND status = 'pending' FOR UPDATE]], ns, t.task_uuid)
            if busy then U.fail(409, "This task is already waiting for an approval") end
            local row = Approvals.create(ns, {
                subject_type = t.compliance and "compliance_close" or "other", action = "complete_task",
                title = "Mark done: " .. t.title, rule = rule,
                payload = { note = data.note, evidence = type(evidence) == "table" and evidence or nil },
                deal_uuid = t.deal_uuid ~= db.NULL and t.deal_uuid or nil, task_uuid = t.task_uuid,
                requested_by_user_uuid = me,
                requested_by_agent = Approvals.is_agent(ns, me) and "service_account" or nil,
            })
            Tasks.update(ns, t.task_uuid, { pd_status = "awaiting_approval" }, me)
            return row
        end)
        return sdk.created(a)
    end)))

    app:get("/tasks/:id/dependencies", sdk.handler({ permission = "property_deals_tasks.read" }, function(self)
        local ns = sdk.namespace_id(self)
        if not Tasks.get(ns, self.params.id) then return sdk.not_found("Task") end
        return sdk.ok(sdk.array(db.query([[
            SELECT dep.depends_on_task_uuid, t.title, d.pd_status
            FROM property_deals_task_dependencies dep
            JOIN property_deals_task_details d ON d.task_uuid = dep.depends_on_task_uuid
            JOIN kanban_tasks t ON t.uuid = dep.depends_on_task_uuid
            WHERE dep.namespace_id = ? AND dep.task_uuid = ?
        ]], ns, self.params.id)))
    end))

    app:post("/tasks/:id/dependencies", sdk.handler({ permission = "property_deals_tasks.update" }, U.guard(function(self)
        local data, bad = input(self, { depends_on_task_uuid = { type = "uuid", required = true } })
        if not data then return bad end
        local ns = sdk.namespace_id(self)
        if not Tasks.get(ns, self.params.id) then return sdk.not_found("Task") end
        if not Tasks.get(ns, data.depends_on_task_uuid) then
            return sdk.error(422, "Validation failed", { depends_on_task_uuid = "not found" })
        end
        -- Refuse cycles: the new prerequisite must not (transitively) wait on this task.
        local cycle = U.one([[
            WITH RECURSIVE up AS (
                SELECT depends_on_task_uuid AS t FROM property_deals_task_dependencies WHERE task_uuid = ?
                UNION SELECT d.depends_on_task_uuid FROM property_deals_task_dependencies d JOIN up ON d.task_uuid = up.t
            ) SELECT 1 FROM up WHERE t = ? LIMIT 1
        ]], data.depends_on_task_uuid, self.params.id)
        if cycle then return sdk.error(422, "Validation failed", { depends_on_task_uuid = "would create a cycle" }) end
        db.insert("property_deals_task_dependencies",
            { namespace_id = ns, task_uuid = self.params.id, depends_on_task_uuid = data.depends_on_task_uuid })
        return sdk.created({ task_uuid = self.params.id, depends_on_task_uuid = data.depends_on_task_uuid })
    end)))

    app:delete("/tasks/:id/dependencies/:dep", sdk.handler({ permission = "property_deals_tasks.update" }, function(self)
        local res = db.query([[
            DELETE FROM property_deals_task_dependencies WHERE namespace_id = ? AND task_uuid = ? AND depends_on_task_uuid = ?
        ]], sdk.namespace_id(self), self.params.id, self.params.dep)
        if res.affected_rows == 0 then return sdk.not_found("Dependency") end
        return sdk.ok()
    end))
end
