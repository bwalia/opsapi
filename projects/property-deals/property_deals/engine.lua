-- Workflow engine (SPEC §3.2): deterministic rules, no AI.
--   enter_stage   set the stage and create its tasks from the deal's pinned template version
--   gate          what stops a deal entering a stage, item by item
--   move          gate check + enter_stage (409 with the missing items when blocked)
--   on_task_done  start dependants, close tasks whose skip_if now holds, repeat tasks
--   retarget      recompute target-relative due times after the deal's dates change
-- Owners: "operator" = the deal owner; "manager"/"compliance" = the first workspace
-- member with that Property Deals role (else the deal owner); "agent" = the deal
-- owner supervises, owner_agent_key names the agent.
local cjson = require("cjson")
local db = require("lapis.db")
local U = require("property_deals.util")
local Days = require("property_deals.workdays")
local Store = require("property_deals.templates_store")
local Template = require("property_deals.template")

local E = {}

-- ---------------------------------------------------------------------------
-- Context
-- ---------------------------------------------------------------------------

--- Everything the rules need about one deal.
function E.context(ns, deal_uuid, settings)
    local deal = require("property_deals.deals").get(ns, deal_uuid)
    if not deal then return nil end
    local version = Store.version(ns, deal.template_version_uuid)
    local property = deal.property_uuid
        and U.one("SELECT * FROM property_deals_properties WHERE uuid = ? AND namespace_id = ?", deal.property_uuid, ns)
    settings = settings or require("helper.plugin-sdk").settings("property_deals", ns)
    return {
        ns = ns, deal = deal, def = version.definition, property = property, settings = settings,
        cal = Days.calendar(ns, settings),
    }
end

-- ---------------------------------------------------------------------------
-- Conditions (`when` / `skip_if`)
-- ---------------------------------------------------------------------------

local function in_list(v, list)
    for _, x in ipairs(list or {}) do if x == v then return true end end
    return false
end

--- Is the property's EPC on file and still in date?
function E.epc_valid(ctx)
    local p = ctx.property
    if not p or not p.epc_certificate_number or p.epc_certificate_number == "" or not p.epc_expires_on then
        return false
    end
    return tostring(p.epc_expires_on) >= Days.today(ctx.cal)
end

--- Does a `when` condition hold for this deal? Unknown keys never match.
function E.when(ctx, cond)
    if type(cond) ~= "table" then return true end
    for k, v in pairs(cond) do
        if k == "tenure" then
            if not (ctx.property and in_list(ctx.property.tenure, v)) then return false end
        elseif k == "deal_type" then
            if not in_list(ctx.deal.deal_type, type(v) == "table" and v or { v }) then return false end
        elseif k == "party_is_company" then
            local any = U.one([[
                SELECT 1 FROM property_deals_deal_parties WHERE deal_uuid = ? AND account_uuid IS NOT NULL LIMIT 1
            ]], ctx.deal.uuid) ~= nil
            if any ~= (v == true) then return false end
        elseif k == "epc_valid" then
            if E.epc_valid(ctx) ~= (v == true) then return false end
        else
            return false
        end
    end
    return true
end

-- ---------------------------------------------------------------------------
-- Owners
-- ---------------------------------------------------------------------------

--- Members of the workspace holding a Property Deals role, most senior first.
function E.members_with_role(ns, role_name)
    local rows = db.query([[
        SELECT DISTINCT u.uuid FROM namespace_user_roles ur
        JOIN namespace_roles r ON r.id = ur.namespace_role_id
        JOIN namespace_members m ON m.id = ur.namespace_member_id AND m.status = 'active'
        JOIN users u ON u.id = m.user_id
        WHERE m.namespace_id = ? AND r.role_name = ?
    ]], ns, role_name)
    local out = {}
    for _, r in ipairs(rows) do out[#out + 1] = r.uuid end
    return out
end

--- Who to escalate to: Property Deals managers, else the workspace owners.
function E.managers(ns)
    local list = E.members_with_role(ns, "pd_manager")
    if #list > 0 then return list end
    for _, r in ipairs(db.query([[
        SELECT u.uuid FROM namespace_members m JOIN users u ON u.id = m.user_id
        WHERE m.namespace_id = ? AND m.is_owner AND m.status = 'active'
    ]], ns)) do list[#list + 1] = r.uuid end
    return list
end

local function owner_for(ctx, role)
    if role == "manager" then
        return E.managers(ctx.ns)[1] or ctx.deal.owner_user_uuid
    elseif role == "compliance" then
        return E.members_with_role(ctx.ns, "pd_compliance")[1] or ctx.deal.owner_user_uuid
    end
    return ctx.deal.owner_user_uuid
end

-- ---------------------------------------------------------------------------
-- Due times
-- ---------------------------------------------------------------------------

local function offset(cal, base_ts, due)
    if due.minutes then return Days.plus_minutes(base_ts, due.minutes) end
    if due.hours then return Days.plus_minutes(base_ts, due.hours * 60) end
    return Days.add_to_instant(cal, base_ts, due.working_days)
end

--- When the task is due, given when its clock starts (`start_ts`).
-- @return ISO instant, or nil + reason (e.g. the deal has no target date yet)
function E.due_at(ctx, tdef, start_ts)
    local due = tdef.due or {}
    if due.from == "target_exchange" or due.from == "target_completion" then
        local target = ctx.deal[due.from .. "_date"]
        if not target then return nil, "no " .. due.from:gsub("_", " ") .. " date" end
        local date = Days.add(ctx.cal, tostring(target), due.working_days or 0)
        local at = Days.at(ctx.cal, date)
        if due.minutes or due.hours then at = Days.plus_minutes(at, due.minutes or due.hours * 60) end
        return at
    end
    return offset(ctx.cal, start_ts, due)
end

-- ---------------------------------------------------------------------------
-- Tasks
-- ---------------------------------------------------------------------------

local function deal_tasks(ns, deal_uuid)
    return db.query([[
        SELECT d.*, t.title FROM property_deals_task_details d JOIN kanban_tasks t ON t.uuid = d.task_uuid
        WHERE d.namespace_id = ? AND d.deal_uuid = ? ORDER BY d.created_at, d.id
    ]], ns, deal_uuid)
end

--- Latest task per template key, and the set of keys that are done.
local function by_key(ns, deal_uuid)
    local latest, done = {}, {}
    for _, t in ipairs(deal_tasks(ns, deal_uuid)) do
        if t.template_key then
            latest[t.template_key] = t
            if t.pd_status == "done" then done[t.template_key] = true end
        end
    end
    return latest, done
end

local function prerequisites(tdef)
    local keys = {}
    for _, k in ipairs(tdef.depends_on or {}) do keys[#keys + 1] = k end
    if tdef.due and tdef.due.from == "task_done" and tdef.due.task then keys[#keys + 1] = tdef.due.task end
    return keys
end

local function unmet(keys, done)
    local out = {}
    for _, k in ipairs(keys) do if not done[k] then out[#out + 1] = k end end
    return out
end

-- Start a task's clock now (or at its prerequisite's completion) and set its due time.
local function clock_fields(ctx, tdef, start_ts)
    local due, why = E.due_at(ctx, tdef, start_ts)
    local f = { sla_started_at = start_ts, due_at = due or db.NULL }
    if tdef.sla_minutes then
        f.sla_minutes = tdef.sla_minutes
    elseif due then
        local mins = db.query("SELECT GREATEST(1, EXTRACT(EPOCH FROM (?::timestamptz - ?::timestamptz)) / 60)::int AS m",
            due, start_ts)[1].m
        f.sla_minutes = mins
    end
    return f, why
end

local function close_skipped(ctx, task_uuid, tdef, actor)
    local evidence = { auto = true, rule = tdef.skip_if, reason = "Condition already met: nothing to do" }
    if tdef.skip_if and tdef.skip_if.epc_valid then
        evidence.reason = "A valid EPC is on file (certificate " .. tostring(ctx.property.epc_certificate_number)
            .. ", expires " .. tostring(ctx.property.epc_expires_on) .. ")"
        evidence.epc_certificate_number = ctx.property.epc_certificate_number
        evidence.epc_expires_on = tostring(ctx.property.epc_expires_on)
    end
    require("property_deals.tasks").update(ctx.ns, task_uuid, { pd_status = "done", evidence = cjson.encode(evidence) }, actor)
end

--- Create one template task for the deal.
function E.create_task(ctx, stage_key, tdef, actor, done)
    local keys = prerequisites(tdef)
    local waiting = unmet(keys, done or select(2, by_key(ctx.ns, ctx.deal.uuid)))
    local fields = {
        title = tdef.title, description = tdef.description, priority = tdef.priority,
        deal = ctx.deal, stage_key = stage_key, template_key = tdef.key,
        blocking = tdef.blocking, compliance = tdef.compliance,
        agent_eligible = tdef.agent and tdef.agent.eligible == true or false,
        agent_key = tdef.agent and tdef.agent.agent_key or nil,
        approval_rule = tdef.approval == "none" and "none" or tdef.approval,
        owner_user_uuid = owner_for(ctx, tdef.owner),
        owner_agent_key = tdef.owner == "agent" and tdef.agent and tdef.agent.agent_key or nil,
        metadata = { depends_on_keys = U.array(keys), waiting_on = U.array(waiting), template_task = tdef.key,
                     agent_auto = tdef.agent and tdef.agent.auto == true or nil },
    }
    local why
    if #waiting == 0 then
        local base = Days.now()
        if tdef.due and tdef.due.from == "stage_entry" then base = ctx.deal.stage_entered_at_iso or base end
        if tdef.due and tdef.due.from == "deal_created" then base = ctx.deal.created_at_iso or base end
        local clock
        clock, why = clock_fields(ctx, tdef, base)
        fields.due_at = clock.due_at ~= db.NULL and clock.due_at or nil
        fields.sla_minutes = clock.sla_minutes
    end
    if why then fields.metadata.due_note = why end
    local task = require("property_deals.tasks").create(ctx.ns, fields, actor)
    if #waiting > 0 then
        db.update("property_deals_task_details", { sla_started_at = db.NULL }, { task_uuid = task.task_uuid })
    end
    -- Real dependency rows for prerequisites that already exist.
    local latest = by_key(ctx.ns, ctx.deal.uuid)
    for _, k in ipairs(tdef.depends_on or {}) do
        if latest[k] and latest[k].task_uuid ~= task.task_uuid then
            db.query([[
                INSERT INTO property_deals_task_dependencies (namespace_id, task_uuid, depends_on_task_uuid)
                VALUES (?, ?, ?) ON CONFLICT DO NOTHING
            ]], ctx.ns, task.task_uuid, latest[k].task_uuid)
        end
    end
    if tdef.skip_if and E.when(ctx, tdef.skip_if) then close_skipped(ctx, task.task_uuid, tdef, actor) end
    return task
end

local function deal_times(ns, deal_uuid)
    return U.one([[
        SELECT to_char(stage_entered_at AT TIME ZONE 'UTC', 'YYYY-MM-DD"T"HH24:MI:SS"Z"') AS stage_entered_at_iso,
               to_char(created_at AT TIME ZONE 'UTC', 'YYYY-MM-DD"T"HH24:MI:SS"Z"') AS created_at_iso
        FROM property_deals_deals WHERE namespace_id = ? AND uuid = ?
    ]], ns, deal_uuid)
end

--- Create the stage's tasks (skipping ones that don't apply, and keys the deal
-- already has unless they repeat). Call inside a transaction.
function E.create_stage_tasks(ctx, stage, actor)
    local times = deal_times(ctx.ns, ctx.deal.uuid)
    ctx.deal.stage_entered_at_iso, ctx.deal.created_at_iso = times.stage_entered_at_iso, times.created_at_iso
    local latest, done = by_key(ctx.ns, ctx.deal.uuid)
    local created = {}
    if not E.when(ctx, stage.when) then return created end
    for _, tdef in ipairs(stage.tasks or {}) do
        local existing = latest[tdef.key]
        local open = existing and existing.pd_status ~= "done" and existing.pd_status ~= "cancelled"
        if E.when(ctx, tdef.when) and not open and (not existing or tdef.repeat_every) then
            created[#created + 1] = E.create_task(ctx, stage.key, tdef, actor, done)
            latest[tdef.key] = created[#created]
        end
    end
    return created
end

--- Set the deal's stage (mirrored on crm_deals.stage) and create the stage's tasks.
function E.enter_stage(ns, deal_uuid, stage_key, actor, settings)
    local ctx = E.context(ns, deal_uuid, settings)
    local stage = Template.stage(ctx.def, stage_key)
    if not stage then U.fail(422, "Validation failed", { to = "no stage '" .. tostring(stage_key) .. "' in this deal's template" }) end
    local from = ctx.deal.stage_key
    db.query([[
        UPDATE property_deals_deals SET stage_key = ?, stage_entered_at = NOW(), updated_at = NOW()
        WHERE namespace_id = ? AND uuid = ?
    ]], stage_key, ns, deal_uuid)
    db.query("UPDATE crm_deals SET stage = ?, updated_at = NOW() WHERE uuid = ? AND namespace_id = ?",
        stage_key, ctx.deal.crm_deal_uuid, ns)
    ctx.deal.stage_key = stage_key
    local created = E.create_stage_tasks(ctx, stage, actor)
    -- Parallel stages that follow run alongside this one (e.g. EPC and survey
    -- while searches are out): start their tasks now; the deal's stage stays.
    local _, idx = Template.stage(ctx.def, stage_key)
    for j = idx + 1, #ctx.def.stages do
        local nxt = ctx.def.stages[j]
        if not nxt.parallel then break end
        for _, t in ipairs(E.create_stage_tasks(ctx, nxt, actor)) do created[#created + 1] = t end
    end
    if from ~= stage_key then
        require("helper.plugin-sdk").emit(ns, "property_deals.deal.stage_changed", {
            uuid = deal_uuid, from = from, to = stage_key, by = actor, tasks_created = #created,
        })
    end
    return created
end

-- ---------------------------------------------------------------------------
-- Gates
-- ---------------------------------------------------------------------------

local FIELD_LABELS = {
    agreed_price = "Agreed price", target_completion_date = "Target completion date",
    target_exchange_date = "Target exchange date", property_uuid = "Property", offer_amount = "Offer amount",
    finance_route = "Finance route",
}

--- What stops the deal entering `stage_key`. Each item: { type, key, message }.
function E.gate(ctx, stage_key)
    local stage = Template.stage(ctx.def, stage_key)
    if not stage then return nil, "no stage '" .. tostring(stage_key) .. "' in this deal's template" end
    local g = stage.entry_gate
    local missing = {}
    local function add(kind, key, msg) missing[#missing + 1] = { type = kind, key = key, message = msg } end
    if not g then return { stage = stage_key, ok = true, missing = U.array(missing) } end

    local latest, done = by_key(ctx.ns, ctx.deal.uuid)
    local tasks = Template.tasks_by_key(ctx.def)
    for _, key in ipairs(g.tasks_done or {}) do
        if not done[key] then
            local t = tasks[key]
            local applies = t and E.when(ctx, t.task.when) and E.when(ctx, (Template.stage(ctx.def, t.stage) or {}).when)
            if applies then
                local title = t.task.title
                if latest[key] then
                    add("task", key, title .. " is not done (" .. latest[key].pd_status:gsub("_", " ") .. ")")
                else
                    add("task", key, title .. " has not been started (stage '" .. t.stage .. "')")
                end
            end
        end
    end

    local items = {}
    for _, c in ipairs(ctx.def.compliance or {}) do items[c.key] = c end
    for _, key in ipairs(g.compliance_passed or {}) do
        local item = items[key]
        if item and E.when(ctx, item.when) then
            local row = U.one([[
                SELECT status, expires_at < NOW() AS expired FROM property_deals_compliance_checks
                WHERE namespace_id = ? AND deal_uuid = ? AND check_type = ?
                ORDER BY (status = 'passed') DESC, updated_at DESC LIMIT 1
            ]], ctx.ns, ctx.deal.uuid, key)
            if not row then
                add("compliance", key, item.name .. " has not been started")
            elseif row.status == "passed" and row.expired then
                add("compliance", key, item.name .. " has expired and must be redone")
            elseif row.status ~= "passed" and row.status ~= "waived" then
                add("compliance", key, item.name .. " is not passed (" .. row.status:gsub("_", " ") .. ")")
            end
        end
    end

    for _, cat in ipairs(g.documents or {}) do
        local have = U.one([[
            SELECT 1 FROM property_deals_documents WHERE namespace_id = ? AND category = ?
              AND (deal_uuid = ? OR (property_uuid IS NOT NULL AND property_uuid::text = ?)) LIMIT 1
        ]], ctx.ns, cat, ctx.deal.uuid, ctx.deal.property_uuid or "")
        if not have then add("document", cat, "No " .. cat:gsub("_", " ") .. " document uploaded") end
    end

    for _, f in ipairs(g.fields or {}) do
        if ctx.deal[f] == nil or ctx.deal[f] == db.NULL then
            add("field", f, (FIELD_LABELS[f] or f:gsub("_", " ")) .. " is not set")
        end
    end

    if g.no_open_blocking_enquiries then
        local n = U.one([[
            SELECT COUNT(*)::int AS n FROM property_deals_enquiries
            WHERE namespace_id = ? AND deal_uuid = ? AND status = 'open' AND blocking
        ]], ctx.ns, ctx.deal.uuid).n
        if n > 0 then add("enquiries", "open_blocking", n .. " blocking enquir" .. (n == 1 and "y is" or "ies are") .. " still open") end
    end

    return { stage = stage_key, ok = #missing == 0, missing = U.array(missing) }
end

--- Move a deal to a stage: refused (409) while the stage's gate isn't met.
function E.move(ns, deal_uuid, to, actor, settings)
    local ctx = E.context(ns, deal_uuid, settings)
    if not ctx then U.fail(404, "Deal not found") end
    if ctx.deal.status ~= "active" then U.fail(409, "The deal is " .. ctx.deal.status:gsub("_", " ")) end
    local gate, err = E.gate(ctx, to)
    if not gate then U.fail(422, "Validation failed", { to = err }) end
    if not gate.ok then
        local lines = {}
        for _, m in ipairs(gate.missing) do lines[#lines + 1] = m.message end
        U.fail(409, "Can't move to '" .. to .. "': " .. table.concat(lines, "; "), { missing = gate.missing })
    end
    return E.enter_stage(ns, deal_uuid, to, actor, settings)
end

--- The next stage on the critical path that applies to this deal (skips
-- optional and parallel stages — parallel ones start with the stage before them).
function E.next_stage(ctx)
    local _, i = Template.stage(ctx.def, ctx.deal.stage_key)
    for j = (i or 0) + 1, #ctx.def.stages do
        local s = ctx.def.stages[j]
        if E.when(ctx, s.when) and not s.optional and not s.parallel then return s.key end
    end
end

-- ---------------------------------------------------------------------------
-- Reacting to changes
-- ---------------------------------------------------------------------------

--- A task became done: start the clocks of tasks that were waiting on it,
-- close tasks whose skip_if now holds, and queue the next run of repeating tasks.
function E.on_task_done(ns, task, actor)
    if not task.deal_uuid then return end
    local ctx = E.context(ns, task.deal_uuid)
    if not ctx then return end
    -- EPC register check evidence ({ epc_valid, certificate_number, expires_on }) updates the property.
    local ev = U.json(task.evidence) or {}
    if type(ev) == "table" and ev.epc_valid == true and ctx.property and ev.certificate_number and ev.expires_on then
        db.update("property_deals_properties", {
            epc_certificate_number = ev.certificate_number, epc_expires_on = ev.expires_on,
            epc_rating = ev.rating or ctx.property.epc_rating or db.NULL, updated_at = db.raw("NOW()"),
        }, { uuid = ctx.property.uuid, namespace_id = ns })
        ctx.property = U.one("SELECT * FROM property_deals_properties WHERE uuid = ?", ctx.property.uuid)
    end

    E.reevaluate(ctx, actor)

    local tasks = Template.tasks_by_key(ctx.def)
    local now = Days.now()
    local tdef = task.template_key and tasks[task.template_key] and tasks[task.template_key].task
    if tdef and tdef.repeat_every and task.stage_key == ctx.deal.stage_key then
        local next_due = Days.add_to_instant(ctx.cal, now, tdef.repeat_every.working_days or 1)
        require("property_deals.tasks").create(ns, {
            title = tdef.title, description = tdef.description, priority = tdef.priority, deal = ctx.deal,
            stage_key = task.stage_key, template_key = tdef.key, blocking = tdef.blocking, compliance = tdef.compliance,
            agent_eligible = tdef.agent and tdef.agent.eligible == true or false,
            agent_key = tdef.agent and tdef.agent.agent_key or nil,
            approval_rule = tdef.approval == "none" and "none" or tdef.approval,
            owner_user_uuid = task.owner_user_uuid, due_at = next_due, sla_started_at = now,
            sla_minutes = math.max(1, db.query("SELECT (EXTRACT(EPOCH FROM (?::timestamptz - ?::timestamptz)) / 60)::int AS m",
                next_due, now)[1].m),
            metadata = { repeat_of = task.task_uuid, template_task = tdef.key },
        }, actor)
    end
end

--- Close open tasks whose skip_if now holds and start the clocks of tasks
-- whose prerequisites are all done. Runs after any task completes and when a
-- deal's property changes (events/engine.lua).
function E.reevaluate(ctx, actor)
    local ns = ctx.ns
    local tasks = Template.tasks_by_key(ctx.def)
    local _, done = by_key(ns, ctx.deal.uuid)
    local now = Days.now()
    for _, t in ipairs(deal_tasks(ns, ctx.deal.uuid)) do
        if t.pd_status ~= "done" and t.pd_status ~= "cancelled" and t.template_key and tasks[t.template_key] then
            local tdef = tasks[t.template_key].task
            if tdef.skip_if and E.when(ctx, tdef.skip_if) then
                close_skipped(ctx, t.task_uuid, tdef, actor)
            elseif t.sla_started_at == nil or t.sla_started_at == db.NULL then
                if #unmet(prerequisites(tdef), done) == 0 then
                    local fields = clock_fields(ctx, tdef, now)
                    local meta = U.json(t.metadata) or {}
                    meta.waiting_on = U.array({})
                    fields.metadata = cjson.encode(meta)
                    require("property_deals.tasks").update(ns, t.task_uuid, fields, actor)
                end
            end
        end
    end
end

--- The deal's target dates changed: re-time open tasks that count from them.
function E.retarget(ns, deal_uuid, actor)
    local ctx = E.context(ns, deal_uuid)
    if not ctx then return end
    local tasks = Template.tasks_by_key(ctx.def)
    for _, t in ipairs(deal_tasks(ns, deal_uuid)) do
        local tdef = t.template_key and tasks[t.template_key] and tasks[t.template_key].task
        if tdef and t.pd_status ~= "done" and t.pd_status ~= "cancelled" and tdef.due
            and (tdef.due.from == "target_exchange" or tdef.due.from == "target_completion") then
            local due = E.due_at(ctx, tdef, Days.now())
            require("property_deals.tasks").update(ns, t.task_uuid, {
                due_at = due or db.NULL, sla_warned_at = db.NULL, sla_breached_at = db.NULL,
            }, actor)
        end
    end
end

return E
