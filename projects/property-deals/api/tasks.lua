-- Deal tasks: /api/v2/property-deals/tasks. Each is a kanban task + details.
--   GET    /tasks               list ?deal_uuid=&pd_status=a,b&owner_user_uuid=&open=true&blocking=true&compliance=true&sort=urgency|due|created
--   GET    /tasks/:id           one task (id = kanban task uuid)
--   POST   /tasks               ad-hoc task on a deal (workflow tasks are created by the engine)
--   PUT    /tasks/:id           update status, owner, due time, snooze...
--   GET    /tasks/:id/dependencies, POST /tasks/:id/dependencies {depends_on_task_uuid}, DELETE /tasks/:id/dependencies/:dep
local root = debug.getinfo(1, "S").source:match("^@(.+)/api/[^/]+%.lua$")
if root and not package.path:find(root .. "/?.lua", 1, true) then package.path = root .. "/?.lua;" .. package.path end

local sdk = require("helper.plugin-sdk")
local db = require("lapis.db")
local U = require("property_deals.util")
local Tasks = require("property_deals.tasks")
local Deals = require("property_deals.deals")
local Workspace = require("property_deals.workspace")

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

    app:post("/tasks", sdk.handler({ permission = "property_deals_tasks.create" }, U.guard(function(self)
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
        local ns = sdk.namespace_id(self)
        local current = Tasks.get(ns, self.params.id)
        if not current then return sdk.not_found("Task") end
        -- Hard rule 6: a compliance task is closed by a named human, with a note or evidence.
        if data.pd_status == "done" and current.compliance then
            local ev = data.evidence or current.evidence
            if ev == nil or ev == db.NULL or ev == "{}" or (type(ev) == "table" and next(ev) == nil) then
                return sdk.error(422, "Validation failed",
                    { evidence = "a compliance task needs evidence (e.g. {\"note\": ..., \"document_uuid\": ...}) to close" })
            end
        end
        if data.snoozed_until and data.snoozed_until ~= db.NULL and not (data.snooze_reason or current.snooze_reason) then
            return sdk.error(422, "Validation failed", { snooze_reason = "is required when snoozing" })
        end
        local task = U.tx(function() return Tasks.update(ns, current.task_uuid, data, sdk.user(self).uuid) end)
        if task.deal_uuid then require("property_deals.health").recompute_deal(ns, task.deal_uuid, sdk.settings(self)) end
        return sdk.ok(Tasks.get(ns, current.task_uuid))
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
