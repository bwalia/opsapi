-- Agent task lifecycle (SPEC §3.5):
--
--   todo ──("Let AI do it" / auto pickup)──► agent_running ──► awaiting_approval ──approve──► done (action run)
--                                                │                    └──reject + note──► todo (rerun uses the note)
--                                                └──error / nothing to send──► todo + a comment for a person
--
-- Built-in agents call the workspace's own models (lib/ai-providers.lua) through
-- the job type's chain (fallback order, local-only, cost caps). JobShout agents
-- are launched on JobShout and polled by jobs/agents_tick.lua; JobShout's own
-- approvals are mirrored into ours so one person's click covers both.
local cjson = require("cjson")
local db = require("lapis.db")
local U = require("property_deals.util")
local G = require("property_deals.ai.guard")
local Agents = require("property_deals.ai.agents")
local Config = require("property_deals.ai.config")

local R = {}

local MAX_ROUNDS = 5
-- Agents run in the background: one model answer may take CALL_TIMEOUT_MS, a whole run RUN_DEADLINE_S
-- (under the tick's 15-minute timeout, so a slow model can't outlive its run).
local CALL_TIMEOUT_MS = 120000
local RUN_DEADLINE_S = 600
-- Rules from least to most strict: settings may raise an agent's rule, never lower it.
local RANK = { none = 0, any_operator = 1, manager = 2, two_person = 3 }
-- Started without a person clicking: the workspace setting ai_auto_runs switches these off.
local AUTO_TRIGGERS = { auto = true, email = true, news = true }

local function settings(ns)
    return require("helper.plugin-sdk").settings("property_deals", ns)
end

local function run_row(ns, uuid)
    return U.one("SELECT * FROM property_deals_agent_runs WHERE namespace_id = ? AND uuid = ?", ns, uuid)
end

--- Record on the run. A status only lands while the run is still running: one the tick timed out, or a
-- person cancelled, stays that way. @return true when it landed
local function finish(run, changes)
    changes.updated_at = db.raw("NOW()")
    if not changes.status then
        db.update("property_deals_agent_runs", changes, { id = run.id })
        return true
    end
    changes.finished_at = changes.finished_at or db.raw("NOW()")
    local r = db.update("property_deals_agent_runs", changes, { id = run.id, status = "running" }, "cost_usd")[1]
    if not r then return false end
    pcall(require("property_deals.metrics").agent_run, run.namespace_id, run.agent_key, changes.status,
        tonumber(r.cost_usd))
    return true
end

local function fail(ns, run, task, message)
    -- Not running any more: whoever stopped it already gave the task back.
    if not finish(run, { status = "failed", error = tostring(message):sub(1, 2000) }) then
        return nil, "the run had already ended"
    end
    if task then
        require("property_deals.approvals").back_to_todo(ns, task.task_uuid, "AI couldn't finish: " .. tostring(message),
            run.triggered_by_user_uuid ~= db.NULL and run.triggered_by_user_uuid or nil)
        local owner = task.owner_user_uuid ~= db.NULL and task.owner_user_uuid or nil
        require("property_deals.notify").send(ns, { owner }, { kind = "agent_update", event = "property_deals.agent.failed",
            route = "task", uuid = task.task_uuid, deal_uuid = task.deal_uuid ~= db.NULL and task.deal_uuid or nil,
            title = "AI couldn't finish", body = task.title })
    end
    return nil, message
end

--- The reviewer's note on the last rejected draft for this task, if any.
local function last_reject_note(ns, task_uuid)
    local r = U.one([[
        SELECT decisions FROM property_deals_approvals WHERE namespace_id = ? AND task_uuid = ? AND status = 'rejected'
        ORDER BY decided_at DESC LIMIT 1
    ]], ns, task_uuid)
    if not r then return nil end
    local ds = U.json(r.decisions) or {}
    local last = ds[#ds]
    return last and last.note ~= cjson.null and last.note or nil
end

--- Why a task in this status can't take a new run (nil = it can).
local function busy(status)
    if status == "done" or status == "cancelled" then return "The task is " .. status end
    if status == "agent_running" or status == "awaiting_approval" then
        return "An agent is already on it (" .. status .. ")"
    end
end

--- Run it on a timer (in the background); if the timer is lost, agents_tick picks the run up.
function R.schedule(ns, run_uuid)
    local ok, err = ngx.timer.at(0, function(premature)
        if premature then return end
        local fine, e = pcall(R.execute, ns, run_uuid)
        if not fine then ngx.log(ngx.ERR, "[property_deals] agent run ", run_uuid, ": ", tostring(e)) end
    end)
    if not ok then
        ngx.log(ngx.WARN, "[property_deals] agent timer: ", tostring(err), " (agents_tick will pick it up)")
    end
    return ok
end

--- Start an agent on a task. opts: { actor, trigger = manual|auto|email|news|retry, retry_note? }
-- @return run row | nil, message, status
function R.start(ns, task_uuid, opts)
    opts = opts or {}
    local Tasks = require("property_deals.tasks")
    local task = Tasks.get(ns, task_uuid)
    if not task then return nil, "Task not found", 404 end
    if not task.agent_eligible or task.agent_key == db.NULL or not task.agent_key then
        return nil, "This task isn't set up for an AI agent", 422
    end
    if busy(task.pd_status) then return nil, busy(task.pd_status), 409 end
    local agent = Agents.get(task.agent_key)
    if not agent then return nil, "The '" .. task.agent_key .. "' agent isn't available yet", 422 end
    -- The digest writer only rewrites a person's digest: there is nothing for it to draft on a task.
    if not agent.context or not agent.draft then return nil, agent.name .. " can't work on a task", 422 end
    local s = settings(ns) or {}
    if AUTO_TRIGGERS[opts.trigger] and s.ai_auto_runs == false then
        return nil, "Automatic AI runs are switched off for this workspace", 422
    end
    local cfg = Config.agent(ns, task.agent_key)
    if not cfg.enabled then return nil, agent.name .. " is switched off for this workspace", 422 end
    if agent.needs_deal and (not task.deal_uuid or task.deal_uuid == db.NULL) then
        return nil, agent.name .. " needs a task on a deal", 422
    end
    if agent.needs_lead and (not task.lead_uuid or task.lead_uuid == db.NULL) then
        return nil, agent.name .. " needs a task on a lead", 422
    end
    if cfg.route ~= "jobshout" and #Config.route(ns, agent.job_type).chain == 0 then
        return nil, "No AI provider is set up (Settings → AI providers)", 422
    end
    local over = Config.over_budget(ns, Config.caps(s))
    if over then return nil, over, 429 end
    -- The task row is locked while the run is created (and an index allows one open run per task), so a
    -- double click, or a click racing an email, starts one run.
    local ok, run = pcall(U.tx, function()
        local t = U.one([[SELECT pd_status FROM property_deals_task_details
            WHERE namespace_id = ? AND task_uuid = ? FOR UPDATE]], ns, task_uuid)
        if not t then U.fail(404, "Task not found") end
        if busy(t.pd_status) then U.fail(409, busy(t.pd_status)) end
        local attempt = U.one([[SELECT COUNT(*)::int AS n FROM property_deals_agent_runs
            WHERE namespace_id = ? AND task_uuid = ?]], ns, task_uuid).n + 1
        local row = db.insert("property_deals_agent_runs", {
            namespace_id = ns, task_uuid = task_uuid, deal_uuid = task.deal_uuid ~= db.NULL and task.deal_uuid or nil,
            agent_key = task.agent_key, provider = cfg.route == "jobshout" and "jobshout" or "builtin",
            prompt_version = agent.version, status = "queued", trigger = opts.trigger or "manual", attempt = attempt,
            retry_note = opts.retry_note or last_reject_note(ns, task_uuid), triggered_by_user_uuid = opts.actor,
        }, { returning = "*" })[1]
        Tasks.update(ns, task_uuid, { pd_status = "agent_running" }, opts.actor)
        return row
    end)
    if not ok then
        if type(run) == "table" and run.pd_error then return nil, run.message, run.status end
        if tostring(run):find("idx_pd_agent_runs_one_open", 1, true) then
            return nil, "An agent is already on it", 409
        end
        error(run, 0)
    end
    if opts.sync then R.execute(ns, run.uuid) else R.schedule(ns, run.uuid) end
    return run_row(ns, run.uuid)
end

local function context(ns, run)
    local task = require("property_deals.tasks").get(ns, run.task_uuid)
    local ctx = { ns = ns, run = run, task = task, task_uuid = run.task_uuid,
        deal_uuid = run.deal_uuid ~= db.NULL and run.deal_uuid or nil }
    if task and task.property_uuid and task.property_uuid ~= db.NULL then ctx.property_uuid = task.property_uuid end
    if task and task.lead_uuid and task.lead_uuid ~= db.NULL then ctx.lead_uuid = task.lead_uuid end
    if not ctx.property_uuid and ctx.deal_uuid then
        local d = U.one("SELECT property_uuid FROM property_deals_deals WHERE namespace_id = ? AND uuid = ?",
            ns, ctx.deal_uuid)
        if d and d.property_uuid ~= db.NULL then ctx.property_uuid = d.property_uuid end
    end
    return ctx, task
end

--- The approval rule for an agent's draft: the strictest of the agent's own (offer reasoning is
-- manager-only), the task's, the lead's (a vulnerable person: a manager reads every word) and the
-- workspace's agent setting. So a setting can only raise the rule.
local function rule_for(ns, agent, task, cfg)
    local rule = "any_operator"
    local function raise(r) if RANK[r] and RANK[r] > RANK[rule] then rule = r end end
    raise(agent.approval)
    raise(task.approval_rule)
    raise(cfg.approval_rule)
    if task.lead_uuid and task.lead_uuid ~= db.NULL and U.one([[SELECT 1 FROM property_deals_lead_details
            WHERE namespace_id = ? AND lead_uuid = ? AND vulnerability_flag]], ns, task.lead_uuid) then
        raise("manager")
    end
    return rule
end

--- Turn the model's (or JobShout's) output into an approval, or hand the task back. Only a run that is
-- still running does: one the tick timed out (or a person cancelled) gave the task back already, so its
-- late answer is dropped.
local function deliver(ns, run, task, agent, cfg, out)
    local ctx = context(ns, run)
    local req = agent.draft and agent.draft(ctx, out or {}) or nil
    local summary = G.text(out and out.summary, 1000)
    if not req then
        if finish(run, { status = "succeeded" }) then
            require("property_deals.approvals").back_to_todo(ns, task.task_uuid,
                "AI found nothing to send" .. (summary and (": " .. summary) or "."), nil)
        end
        return run_row(ns, run.uuid)
    end
    local rule = rule_for(ns, agent, task, cfg)
    -- One draft, or several (the buyer matcher writes one pack per buyer).
    local list = req.action and { req } or req
    local delivered, a = U.tx(function()
        if not finish(run, { status = "succeeded" }) then return false end
        local last
        for _, r in ipairs(list) do
            last = require("property_deals.approvals").create(ns, {
                subject_type = r.subject_type, action = r.action, title = r.title, payload = r.payload, rule = rule,
                agent_run_uuid = run.uuid, task_uuid = task.task_uuid,
                deal_uuid = task.deal_uuid ~= db.NULL and task.deal_uuid or nil, requested_by_agent = run.agent_key,
            })
        end
        require("property_deals.tasks").update(ns, task.task_uuid, { pd_status = "awaiting_approval" }, nil)
        return true, last
    end)
    if not delivered then
        ngx.log(ngx.NOTICE, "[property_deals] agent run ", run.uuid, " had ended before its answer came: dropped")
    end
    return run_row(ns, run.uuid), a
end

-- ---------------------------------------------------------------------------
-- Built-in models
-- ---------------------------------------------------------------------------

local function builtin(ns, run, task, agent, cfg)
    local ctx = context(ns, run)
    local route = Config.route(ns, agent.job_type)
    if #route.chain == 0 then return fail(ns, run, task, "No AI provider is set up (Settings → AI providers)") end
    local caps = Config.caps(settings(ns))
    local local_only = route.local_only or cfg.local_only == true
    local tools = #agent.tools > 0 and require("property_deals.ai.tools").schemas(agent.tools) or nil
    local intro = "Task: " .. tostring(task.title)
    if run.retry_note and run.retry_note ~= db.NULL then
        intro = intro .. "\nA reviewer rejected your last draft with this note (follow it): " .. run.retry_note
    end
    local messages = {
        { role = "system", content = G.PREAMBLE .. "\n\n[agent:" .. run.agent_key .. "]\n" .. agent.instructions },
        { role = "user", content = intro .. "\n\nRecords for this task:\n" .. G.fence("records", agent.context(ctx)) },
    }
    ngx.update_time()
    local steps, tokens_in, tokens_out, cost, started = {}, 0, 0, 0, ngx.now()
    local info, out
    local fell_back = run.fallback_used == true
    local opts = { local_only = local_only, json = true, max_tokens = route.max_tokens or caps.max_tokens,
        timeout_ms = CALL_TIMEOUT_MS, feature = "property_deals:" .. run.agent_key, run_uuid = run.uuid,
        user_uuid = run.triggered_by_user_uuid ~= db.NULL and run.triggered_by_user_uuid or nil }
    for round = 1, MAX_ROUNDS do
        -- Before every model call: still ours (not timed out or cancelled), in time, within today's allowance.
        if not U.one("SELECT 1 FROM property_deals_agent_runs WHERE id = ? AND status = 'running'", run.id) then
            return run_row(ns, run.uuid)
        end
        ngx.update_time()
        local stop = ngx.now() - started > RUN_DEADLINE_S and "Stopped: the run took too long"
            or Config.over_budget(ns, caps)
        if stop then
            finish(run, { steps = cjson.encode(U.array(steps)) })
            return fail(ns, run, task, stop)
        end
        local msg, i = require("lib.ai-providers").chat(ns, route.chain, messages, tools, opts)
        if not msg and tools then
            -- Plain JSON fallback for models without tool calling: the records are already in the prompt.
            steps[#steps + 1] = { round = round, note = "retrying without tools", error = tostring(i):sub(1, 300) }
            tools = nil
            msg, i = require("lib.ai-providers").chat(ns, route.chain, messages, nil, opts)
        end
        if not msg then
            finish(run, { steps = cjson.encode(U.array(steps)) })
            return fail(ns, run, task, i)
        end
        info = i
        if i.attempts and #i.attempts > 0 then fell_back = true end
        -- Stay on the provider that answered for the rest of this run (don't retry a down one every round).
        for idx, link in ipairs(route.chain) do
            if link.provider_uuid == i.provider_uuid and idx > 1 then
                local rest = {}
                for k = idx, #route.chain do rest[#rest + 1] = route.chain[k] end
                route.chain = rest
                break
            end
        end
        local usage = msg.usage or {}
        tokens_in, tokens_out, cost = tokens_in + (usage.input or 0), tokens_out + (usage.output or 0), cost + (i.cost_usd or 0)
        -- Counted as it's used, so the daily allowance sees this run (and every other one going now).
        finish(run, { tokens_in = tokens_in, tokens_out = tokens_out, cost_usd = cost })
        if caps.run and cost > caps.run then
            finish(run, { steps = cjson.encode(U.array(steps)) })
            return fail(ns, run, task, string.format("Stopped: this run passed its $%.2f cost cap", caps.run))
        end
        if msg.tool_calls and #msg.tool_calls > 0 and round < MAX_ROUNDS then
            messages[#messages + 1] = { role = "assistant", content = msg.content, tool_calls = msg.tool_calls, raw = msg.raw }
            for _, tc in ipairs(msg.tool_calls) do
                local name = tc["function"] and tc["function"].name or ""
                local content
                if not G.allowed(agent, name) then
                    steps[#steps + 1] = { round = round, tool = name, refused = true, reason = "not on this agent's allowlist" }
                    content = cjson.encode({ error = "Tool '" .. name .. "' is not available to you." })
                else
                    local res, untrusted = require("property_deals.ai.tools").run(ctx, name, tc["function"].arguments)
                    steps[#steps + 1] = { round = round, tool = name, args = tc["function"].arguments }
                    content = untrusted and G.fence("tool:" .. name, res) or cjson.encode(res)
                end
                messages[#messages + 1] = { role = "tool", tool_call_id = tc.id, tool_name = name, content = content }
            end
        else
            out = G.json_object(msg.content)
            steps[#steps + 1] = { round = round, reply = true, parsed = out ~= nil }
            if out then break end
            if round < MAX_ROUNDS then
                messages[#messages + 1] = { role = "assistant", content = msg.content }
                messages[#messages + 1] = { role = "user", content = "Reply with the JSON object only." }
            end
        end
    end
    ngx.update_time()
    local fields = {
        steps = cjson.encode(U.array(steps)), tokens_in = tokens_in, tokens_out = tokens_out, cost_usd = cost,
        latency_ms = math.floor((ngx.now() - started) * 1000), model = info and info.model,
        provider_uuid = info and info.provider_uuid,
        fallback_used = fell_back,
        output = out and cjson.encode(out) or nil,
        output_draft = out and G.text(out.email and out.email.body or out.summary, 8000) or nil,
    }
    finish(run, fields)
    run = run_row(ns, run.uuid)
    if not out then return fail(ns, run, task, "The model didn't return a usable draft") end
    return deliver(ns, run, task, agent, cfg, out)
end

-- ---------------------------------------------------------------------------
-- JobShout
-- ---------------------------------------------------------------------------

local function jobshout_row(ns, cfg)
    if not cfg.jobshout_provider_uuid or cfg.jobshout_provider_uuid == db.NULL then return nil end
    return U.one("SELECT * FROM namespace_ai_providers WHERE namespace_id = ? AND uuid = ? AND enabled",
        ns, cfg.jobshout_provider_uuid)
end

local function jobshout(ns, run, task, agent, cfg)
    local row = jobshout_row(ns, cfg)
    local res, err
    if row then
        local ctx = context(ns, run)
        -- Minimal data: what the agent needs for this task, no contact details.
        local prompt = cjson.encode({ agent = run.agent_key, task = task.title, instructions = agent.instructions,
            reviewer_note = run.retry_note ~= db.NULL and run.retry_note or nil, records = agent.context(ctx) })
        local values = { prompt = prompt }
        res, err = require("lib.jobshout-client").launch(ns, row, {
            agent_id = cfg.jobshout_agent_id, project_id = cfg.jobshout_project_id ~= db.NULL and cfg.jobshout_project_id or nil,
            values = values,
        })
    else
        err = "the JobShout link is missing or switched off"
    end
    if res then
        db.update("property_deals_agent_runs", { status = "running",
            jobshout_task_id = type(res.task) == "table" and res.task.id or nil, jobshout_run_id = res.run_id,
            model = "jobshout:" .. tostring(cfg.jobshout_agent_id), provider_uuid = row.uuid, updated_at = db.raw("NOW()"),
        }, { id = run.id })
        return run_row(ns, run.uuid)
    end
    if cfg.fallback_to_builtin then
        db.update("property_deals_agent_runs", { provider = "builtin", fallback_used = true,
            steps = cjson.encode(U.array({ { note = "JobShout unavailable, used the built-in model", error = tostring(err) } })) },
            { id = run.id })
        return builtin(ns, run_row(ns, run.uuid), task, agent, cfg)
    end
    return fail(ns, run, task, "JobShout unavailable: " .. tostring(err))
end

--- Poll one JobShout run: mirror its approvals, finish it when it ends.
function R.poll_jobshout(ns, run, pending_by_execution)
    local task = require("property_deals.tasks").get(ns, run.task_uuid)
    local agent = Agents.get(run.agent_key)
    local cfg = Config.agent(ns, run.agent_key)
    local row = U.one("SELECT * FROM namespace_ai_providers WHERE namespace_id = ? AND uuid = ?", ns, run.provider_uuid)
    if not row or not task or not agent then return fail(ns, run, task, "JobShout link or task disappeared") end
    local r, err = require("lib.jobshout-client").run(ns, row, run.jobshout_run_id)
    if not r then
        ngx.log(ngx.WARN, "[property_deals] JobShout poll: ", tostring(err))
        return nil
    end
    local exec = r.execution_id ~= cjson.null and r.execution_id or nil
    if exec and run.jobshout_execution_id ~= exec then
        db.update("property_deals_agent_runs", { jobshout_execution_id = exec }, { id = run.id })
    end
    -- JobShout asked for approval: one record here, decided once, passed back.
    for _, ja in ipairs(exec and pending_by_execution[exec] or {}) do
        local exists = U.one("SELECT uuid FROM property_deals_approvals WHERE namespace_id = ? AND jobshout_approval_id = ?", ns, ja.id)
        if not exists then
            require("property_deals.approvals").create(ns, {
                subject_type = "agent_draft", action = "jobshout:" .. tostring(ja.tool_name):sub(1, 30),
                title = agent.name .. " (JobShout) wants to " .. tostring(ja.tool_name):gsub("_", " "),
                payload = type(ja.tool_input) == "table" and ja.tool_input or {},
                rule = rule_for(ns, agent, task, cfg),
                agent_run_uuid = run.uuid, task_uuid = task.task_uuid,
                deal_uuid = task.deal_uuid ~= db.NULL and task.deal_uuid or nil, requested_by_agent = run.agent_key,
                jobshout_approval_id = ja.id, jobshout_provider_uuid = row.uuid,
            })
            if task.pd_status ~= "awaiting_approval" then
                require("property_deals.tasks").update(ns, task.task_uuid, { pd_status = "awaiting_approval" }, nil)
            end
        end
    end
    local status = tostring(r.status)
    if status == "failed" then
        finish(run, { tokens_out = tonumber(r.total_tokens) or 0, cost_usd = tonumber(r.cost_usd) or 0 })
        return fail(ns, run, task, "JobShout run failed: " .. tostring(r.error_message ~= cjson.null and r.error_message or "unknown"))
    end
    if status ~= "completed" then return nil end
    local output = r.output ~= cjson.null and r.output or ""
    local out = G.json_object(output) or { summary = output }
    finish(run, { output = cjson.encode(out), output_draft = G.text(output, 8000), tokens_out = tonumber(r.total_tokens) or 0,
        cost_usd = tonumber(r.cost_usd) or 0, latency_ms = tonumber(r.latency_ms) })
    local mirrored = U.one([[
        SELECT COUNT(*)::int AS n, COUNT(*) FILTER (WHERE status = 'executed')::int AS done
        FROM property_deals_approvals WHERE namespace_id = ? AND agent_run_uuid = ?
    ]], ns, run.uuid)
    if mirrored.n > 0 then
        finish(run, { status = "succeeded" })
        -- JobShout did the approved work: the task is done, with JobShout's output as evidence.
        if mirrored.done == mirrored.n and task.pd_status ~= "done" and task.pd_status ~= "cancelled" then
            require("property_deals.tasks").update(ns, task.task_uuid, { pd_status = "done",
                evidence = cjson.encode({ jobshout_run_id = run.jobshout_run_id, output = G.text(output, 2000) }) }, nil)
        end
        return run_row(ns, run.uuid)
    end
    -- No JobShout approval: its output is a draft like a built-in agent's.
    return deliver(ns, run_row(ns, run.uuid), task, agent, cfg, out)
end

--- Run a queued agent run (timer, or agents_tick if the timer was lost). With the workspace's fill of
-- built-in runs already going (ai_max_concurrent_runs) it stays queued; agents_tick starts it later.
function R.execute(ns, run_uuid)
    local run = U.one([[
        UPDATE property_deals_agent_runs SET status = 'running', started_at = NOW(), updated_at = NOW()
        WHERE namespace_id = ? AND uuid = ? AND status = 'queued'
          AND (provider <> 'builtin' OR (SELECT COUNT(*) FROM property_deals_agent_runs
               WHERE namespace_id = ? AND status = 'running' AND provider = 'builtin') < ?)
        RETURNING *
    ]], ns, run_uuid, ns, Config.caps(settings(ns)).concurrent)
    if not run then return nil end
    local task = require("property_deals.tasks").get(ns, run.task_uuid)
    local agent = Agents.get(run.agent_key)
    if not task or not agent then return fail(ns, run, task, "task or agent no longer exists") end
    local cfg = Config.agent(ns, run.agent_key)
    local ok, res, a = pcall(function()
        if run.provider == "jobshout" then return jobshout(ns, run, task, agent, cfg) end
        return builtin(ns, run, task, agent, cfg)
    end)
    if not ok then
        ngx.log(ngx.ERR, "[property_deals] agent ", run.agent_key, " crashed: ", tostring(res))
        return fail(ns, run_row(ns, run.uuid), task, "internal error")
    end
    return res, a
end

--- Daily digest writer: prose for one person's digest (nil = keep the plain one).
function R.write_digest(ns, user_uuid, digest)
    local cfg = Config.agent(ns, "digest_writer")
    if not cfg.enabled then return nil end
    local agent = Agents.get("digest_writer")
    local route = Config.route(ns, agent.job_type)
    if #route.chain == 0 then return nil end
    if Config.over_budget(ns, Config.caps(settings(ns))) then return nil end
    local run = db.insert("property_deals_agent_runs", { namespace_id = ns, agent_key = "digest_writer", provider = "builtin",
        prompt_version = agent.version, status = "running", trigger = "auto", started_at = db.raw("NOW()"),
        triggered_by_user_uuid = user_uuid }, { returning = "*" })[1]
    local msg, info = require("lib.ai-providers").chat(ns, route.chain, {
        { role = "system", content = G.PREAMBLE .. "\n\n" .. agent.instructions },
        { role = "user", content = "Digest:\n" .. G.fence("digest", digest) },
    }, nil, { local_only = route.local_only or cfg.local_only == true, json = true, max_tokens = 600,
        timeout_ms = 60000, feature = "property_deals:digest_writer", run_uuid = run.uuid, user_uuid = user_uuid })
    if not msg then
        finish(run, { status = "failed", error = tostring(info):sub(1, 500) })
        return nil
    end
    local out = G.json_object(msg.content)
    local text = out and G.text(out.summary, 1500)
    local usage = msg.usage or {}
    finish(run, { status = text and "succeeded" or "failed", output = out and cjson.encode(out) or nil, output_draft = text,
        model = info.model, provider_uuid = info.provider_uuid, tokens_in = usage.input or 0, tokens_out = usage.output or 0,
        cost_usd = info.cost_usd or 0, latency_ms = info.latency_ms, error = not text and "no summary in reply" or nil })
    return text
end

return R
