-- Approvals (SPEC §3.5, hard rule 6): nothing leaves the system without a named
-- person's approval, logged with who, when and which version of the payload.
--
--   Approvals.create(ns, data)                     a request (people, agents, JobShout mirror)
--   Approvals.decide(ns, id, me, input, can_manage) approve / reject (+ edit, + version guard)
--   Approvals.execute(ns, id, actor)                carry out an approved action (property_deals.ai.executor)
--
-- Rules: any_operator = one person with approvals.update; manager = one with
-- approvals.manage; two_person = two different people. Nobody decides their own
-- request; the AI service account (pd_agent) never decides. An edit while
-- approving becomes a new payload version (hash recorded, original kept).
-- When JobShout raised the approval, our decision is passed to JobShout, which
-- then runs its own tool: one human click covers both systems.
local cjson = require("cjson")
local db = require("lapis.db")
local U = require("property_deals.util")

local Approvals = {}

function Approvals.sha256_hex(s)
    local sha = require("resty.sha256"):new()
    sha:update(s)
    return require("resty.string").to_hex(sha:final())
end

local function canonical(v)
    if type(v) == "string" then return v end
    return cjson.encode(v == nil and cjson.null or v)
end

function Approvals.get(ns, id)
    if not U.is_uuid(id) then return nil end
    return U.one("SELECT * FROM property_deals_approvals WHERE namespace_id = ? AND uuid = ?", ns, id)
end

function Approvals.is_agent(ns, user_uuid)
    return U.one([[
        SELECT 1 FROM namespace_user_roles ur
        JOIN namespace_roles r ON r.id = ur.namespace_role_id
        JOIN namespace_members m ON m.id = ur.namespace_member_id
        JOIN users u ON u.id = m.user_id
        WHERE m.namespace_id = ? AND u.uuid = ? AND r.role_name = 'pd_agent'
    ]], ns, user_uuid) ~= nil
end

--- Who should hear about a new approval: managers, plus operators unless it's manager-only.
local function approvers(ns, rule, exclude)
    local E = require("property_deals.engine")
    local out, seen = {}, { [exclude or ""] = true }
    local function add(list)
        for _, u in ipairs(list) do if not seen[u] then seen[u] = true; out[#out + 1] = u end end
    end
    add(E.managers(ns))
    if rule ~= "manager" then add(E.members_with_role(ns, "pd_operator")) end
    return out
end

--- data: subject_type, action, title, payload (table|json), rule?, deal_uuid?, task_uuid?,
-- agent_run_uuid?, requested_by_user_uuid?, requested_by_agent?, jobshout_approval_id?, jobshout_provider_uuid?
function Approvals.create(ns, data)
    local row = {}
    for k, v in pairs(data) do row[k] = v end
    row.namespace_id = ns
    row.payload = canonical(data.payload)
    row.payload_sha256 = Approvals.sha256_hex(row.payload)
    row.rule = data.rule or "any_operator"
    -- property_deals.approval.requested comes from the table trigger (a `verb` in project.lua).
    local a = db.insert("property_deals_approvals", row, { returning = "*" })[1]
    require("property_deals.notify").send(ns, approvers(ns, a.rule, a.requested_by_user_uuid), {
        kind = "approval_requested", event = "property_deals.approval.requested", route = "approval", uuid = a.uuid,
        deal_uuid = a.deal_uuid ~= db.NULL and a.deal_uuid or nil, title = "Approval needed", body = a.title,
    })
    return a
end

--- Put the task back in someone's hands with a note (agent failed or draft rejected).
function Approvals.back_to_todo(ns, task_uuid, note, actor)
    if not task_uuid or task_uuid == db.NULL then return end
    local Tasks = require("property_deals.tasks")
    local t = Tasks.get(ns, task_uuid)
    if not t or t.pd_status == "done" or t.pd_status == "cancelled" then return end
    Tasks.update(ns, task_uuid, { pd_status = "todo" }, actor)
    Approvals.comment(ns, task_uuid, note, actor or (t.owner_user_uuid ~= db.NULL and t.owner_user_uuid or nil))
end

--- A comment on the kanban task (best effort).
function Approvals.comment(ns, task_uuid, text, user_uuid)
    if not user_uuid or not text then return end
    local t = U.one("SELECT id FROM kanban_tasks WHERE uuid = ?", task_uuid)
    if not t then return end
    local ok, err = pcall(require("queries.KanbanTaskQueries").addComment,
        { task_id = t.id, user_uuid = user_uuid, content = text })
    if not ok then ngx.log(ngx.WARN, "[property_deals] task comment: ", tostring(err)) end
end

local function mirror_to_jobshout(ns, a, decision, note)
    if not a.jobshout_approval_id or a.jobshout_approval_id == db.NULL then return nil end
    local row = U.one("SELECT * FROM namespace_ai_providers WHERE namespace_id = ? AND uuid = ?", ns, a.jobshout_provider_uuid)
    if not row then return { error = "JobShout link no longer exists" } end
    local res, err = require("lib.jobshout-client").decide(ns, row, a.jobshout_approval_id, decision,
        note or (decision == "approve" and "Approved in Property Deals" or nil))
    if not res then return { error = err } end
    return { ok = true }
end

--- input: { decision, note?, payload? (edited, approve only), payload_version?, payload_sha256? }
function Approvals.decide(ns, id, me, input, can_manage)
    if Approvals.is_agent(ns, me) then U.fail(403, "An AI agent can't decide approvals; a person must") end
    local result = U.tx(function()
        local a = U.one("SELECT * FROM property_deals_approvals WHERE namespace_id = ? AND uuid = ? FOR UPDATE",
            ns, U.is_uuid(id) and id or "00000000-0000-0000-0000-000000000000")
        if not a then U.fail(404, "Approval not found") end
        if a.status ~= "pending" then U.fail(409, "Already " .. a.status) end
        -- Version guard (ios-approval-version-guard): refuse a decision on a draft the person didn't see.
        local seen_v, seen_h = tonumber(input.payload_version), input.payload_sha256
        if (seen_v and seen_v ~= tonumber(a.payload_version)) or (seen_h and seen_h ~= a.payload_sha256) then
            U.fail(409, "The draft has changed since you opened it",
                { payload_version = tonumber(a.payload_version), payload_sha256 = a.payload_sha256 })
        end
        if a.requested_by_user_uuid == me then U.fail(403, "You can't decide your own request") end
        if a.rule == "manager" and not can_manage then U.fail(403, "This needs a manager's approval") end
        local decisions = U.json(a.decisions) or {}
        for _, d in ipairs(decisions) do
            if d.user_uuid == me then U.fail(409, "You have already approved this; it needs someone else") end
        end

        local changes = { updated_at = db.raw("NOW()") }
        local payload_text = canonical(U.json(a.payload))
        if input.payload then
            if not a.original_payload or a.original_payload == db.NULL then changes.original_payload = payload_text end
            changes.payload = canonical(input.payload)
            changes.payload_version = (tonumber(a.payload_version) or 1) + 1
            changes.payload_sha256 = Approvals.sha256_hex(changes.payload)
        end
        decisions[#decisions + 1] = {
            user_uuid = me, decision = input.decision, note = input.note or cjson.null,
            at = require("property_deals.workdays").now(),
            payload_version = changes.payload_version or tonumber(a.payload_version) or 1,
            payload_sha256 = changes.payload_sha256 or a.payload_sha256 or Approvals.sha256_hex(payload_text),
            edited = input.payload ~= nil,
        }
        changes.decisions = cjson.encode(U.array(decisions))

        local final
        if input.decision == "reject" then
            final = "rejected"
        else
            local n = 0
            for _, d in ipairs(decisions) do if d.decision == "approve" then n = n + 1 end end
            if a.rule ~= "two_person" or n >= 2 then final = "approved" end
        end
        if final then changes.status, changes.decided_at = final, db.raw("NOW()") end
        db.update("property_deals_approvals", changes, { id = a.id })
        return { final = final, a = a }
    end)

    local a = result.a
    if result.final then
        require("helper.plugin-sdk").emit(ns, "property_deals.approval.decided", {
            uuid = a.uuid, decision = result.final, rule = a.rule, deal_uuid = a.deal_uuid, task_uuid = a.task_uuid,
            subject_type = a.subject_type, action = a.action, by = me,
        })
        local js = mirror_to_jobshout(ns, a, result.final == "approved" and "approve" or "reject", input.note)
        if result.final == "approved" then
            if js then
                -- JobShout runs its own tool now; we record that it was handed over,
                -- and log an approved email in the chase log like one we sent ourselves.
                local result = js.ok and { by = "jobshout" } or { error = js.error }
                if js.ok and a.action == "jobshout:send_email" and a.deal_uuid ~= db.NULL then
                    local p = U.json(U.one("SELECT payload FROM property_deals_approvals WHERE id = ?", a.id).payload) or {}
                    local chase = db.insert("property_deals_chases", {
                        namespace_id = ns, deal_uuid = a.deal_uuid, task_uuid = a.task_uuid ~= db.NULL and a.task_uuid or nil,
                        to_party = "other", to_address = type(p.to) == "string" and p.to or nil,
                        channel = "email", subject = type(p.subject) == "string" and p.subject:sub(1, 255) or a.title,
                        body = type(p.body) == "string" and p.body or nil, status = "sent", sent_at = db.raw("NOW()"),
                        sent_by_user_uuid = me, approval_uuid = a.uuid,
                    }, { returning = "*" })[1]
                    result.chase_uuid = chase.uuid
                end
                db.update("property_deals_approvals", {
                    status = js.ok and "executed" or "failed", executed_at = js.ok and db.raw("NOW()") or db.NULL,
                    execution_result = cjson.encode(result),
                    execution_attempts = db.raw("execution_attempts + 1"),
                }, { id = a.id })
            else
                Approvals.execute(ns, a.uuid, me)
            end
        else
            if a.agent_run_uuid and a.agent_run_uuid ~= db.NULL then
                db.update("property_deals_agent_runs", { retry_note = input.note }, { uuid = a.agent_run_uuid })
            end
            Approvals.back_to_todo(ns, a.task_uuid ~= db.NULL and a.task_uuid or nil,
                "Draft rejected: " .. tostring(input.note) .. " — run the agent again to redraft with this note.", me)
        end
    end
    local row = Approvals.get(ns, id)
    row.waiting_for = result.final == nil and "a second person" or nil
    return row
end

--- Carry out an approved action once (claimed by the UPDATE). Failures leave the
-- approval `failed` with the reason; POST /approvals/:id/retry runs it again.
function Approvals.execute(ns, id, actor)
    local a = U.one([[
        UPDATE property_deals_approvals SET execution_attempts = execution_attempts + 1, updated_at = NOW(),
            execution_result = '{"running": true}'::jsonb
        WHERE namespace_id = ? AND uuid = ? AND status IN ('approved', 'failed') AND executed_at IS NULL
          AND (execution_result IS NULL OR execution_result ->> 'running' IS NULL
               OR updated_at < NOW() - interval '10 minutes')
        RETURNING *
    ]], ns, id)
    if not a then return nil, "not ready to execute" end
    local Executor = require("property_deals.ai.executor")
    local ok, res, err = pcall(Executor.run, ns, a, actor)
    if ok and res then
        db.update("property_deals_approvals", { status = "executed", executed_at = db.raw("NOW()"),
            execution_result = cjson.encode(res.result or {}) }, { id = a.id })
        if res.task_status and a.task_uuid and a.task_uuid ~= db.NULL then
            local Tasks = require("property_deals.tasks")
            local t = Tasks.get(ns, a.task_uuid)
            if t and t.pd_status ~= "done" and t.pd_status ~= "cancelled" then
                local changes = { pd_status = res.task_status }
                if res.task_status == "done" then
                    changes.evidence = cjson.encode({ approval_uuid = a.uuid, result = res.result })
                end
                Tasks.update(ns, a.task_uuid, changes, actor)
            end
        end
        if a.deal_uuid and a.deal_uuid ~= db.NULL then
            pcall(require("property_deals.health").recompute_deal, ns, a.deal_uuid,
                require("helper.plugin-sdk").settings("property_deals", ns))
        end
        return res
    end
    local reason = ok and err or res
    if type(reason) == "table" then reason = reason.message or cjson.encode(reason) end
    ngx.log(ngx.WARN, "[property_deals] approval ", a.uuid, " execution failed: ", tostring(reason))
    db.update("property_deals_approvals", { status = "failed",
        execution_result = cjson.encode({ error = tostring(reason) }) }, { id = a.id })
    return nil, tostring(reason)
end

return Approvals
