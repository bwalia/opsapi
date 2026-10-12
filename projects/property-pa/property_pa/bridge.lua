-- PA chat: OpsAPI asks, JobShout's Seller / Manager PA answers, OpsAPI checks the answer before anyone sees it.
--
--   B.ask(ns, user_uuid, settings, req)   start a run (one JobShout task per person and role, a run per turn)
--   B.poll(ns, run)                       ask JobShout for the result (fallback when no webhook arrives)
--   B.finish(ns, run, data)               store the result: parse the pa_output block, run the grounding check,
--                                         record model + prompt version (audit). Idempotent.
--
-- Runs are property_deals_agent_runs rows (one audit table for every agent) with provider "jobshout-pa", so the
-- deals tick that polls its own JobShout runs leaves these alone.
local cjson = require("cjson")
local db = require("lapis.db")
local U = require("property_deals.util")
local G = require("property_pa.grounding")

local B = {}

B.PROVIDER = "jobshout-pa"
B.SKILLS = { today = "pa-today", prepare = "pa-prepare-me", capture = "pa-capture", coach = "pa-coach",
    handoff = "pa-handoff", manager_today = "pa-manager-today", teach = "pa-teach", ask = false }
B.MANAGER_ONLY = { manager_today = true, teach = true }
-- pa_output source types -> the OpsAPI table a bare id belongs to
B.SOURCE_TABLES = { person = "crm_contacts", lead = "crm_leads", property = "property_deals_properties",
    opportunity = "pa_opportunities", interaction = "crm_activities", event = "pa_events", offer = "pa_offers",
    task = "property_deals_task_details", knowledge = "pa_knowledge", handoff = "pa_handoffs" }

local function null(v) return v == nil or v == db.NULL or v == cjson.null end
local function nz(v) return not null(v) and v ~= "" and v or nil end

local function link(ns, settings)
    local id = nz(settings.jobshout_provider_uuid)
    local row = id and U.is_uuid(id) and U.one([[SELECT * FROM namespace_ai_providers WHERE namespace_id = ? AND uuid = ?
        AND provider_type = 'jobshout' AND enabled]], ns, id)
    if not row then U.fail(409, "The PA isn't connected: set the JobShout link in the Property PA settings") end
    return row
end

B.SELECT = [[
    SELECT uuid, agent_key, status, model, prompt_version, input_snapshot, output, error, jobshout_task_id,
           jobshout_run_id, triggered_by_user_uuid, tokens_out, cost_usd, latency_ms, started_at, finished_at, created_at
    FROM property_deals_agent_runs
]]

function B.get(ns, uuid, user_uuid)
    if not U.is_uuid(uuid) then return nil end
    return U.one(B.SELECT .. " WHERE namespace_id = ? AND uuid = ?::uuid AND provider = ? AND triggered_by_user_uuid = ?",
        ns, uuid, B.PROVIDER, user_uuid)
end

--- One ai_usage row (core metering, the same columns lib/agent/llm writes), so PA runs show on the AI usage page
-- and count towards AI_USER_DAILY_TOKEN_LIMIT. Never fails the caller: a lost row is logged.
local function meter(ns, user, run_uuid, scope, model, input, output, ms, err)
    local ok, ierr = pcall(db.insert, "ai_usage", { namespace_id = ns, user_uuid = nz(user), feature = "property_pa",
        scope = nz(scope), run_uuid = run_uuid, provider = "jobshout",
        model = tostring(model or "jobshout"):sub(1, 120), input_tokens = input or 0, output_tokens = output or 0,
        latency_ms = ms or 0, ok = err == nil, error = err })
    if not ok then ngx.log(ngx.ERR, "[property_pa] usage not recorded: ", tostring(ierr)) end
end

--- AI_USER_DAILY_TOKEN_LIMIT, counted the way lib/agent/llm counts it (tokens per user per UTC day, every feature).
local function over_daily_limit(user_uuid)
    local limit = tonumber(os.getenv("AI_USER_DAILY_TOKEN_LIMIT") or "")
    if not limit then return false end
    local r = U.one([[SELECT COALESCE(SUM(input_tokens + output_tokens), 0) AS used FROM ai_usage WHERE user_uuid = ?
        AND created_at >= date_trunc('day', NOW() AT TIME ZONE 'UTC') AT TIME ZONE 'UTC']], user_uuid)
    return tonumber(r.used) >= limit
end

-- Limits per person (hardening for real use): runs in flight, and runs per hour.
B.MAX_RUNNING = 3
B.MAX_PER_HOUR = 60
B.TIMEOUT_MINUTES = 30

--- req = { message, mode, role, opportunity_uuid?, interaction_uuid?, inputs? } @return run row
function B.ask(ns, user_uuid, settings, req)
    local load = U.one([[SELECT COUNT(*) FILTER (WHERE status = 'running')::int AS running,
        COUNT(*) FILTER (WHERE created_at > NOW() - INTERVAL '1 hour')::int AS hour
        FROM property_deals_agent_runs WHERE namespace_id = ? AND provider = ? AND triggered_by_user_uuid = ?
        AND created_at > NOW() - INTERVAL '1 hour']], ns, B.PROVIDER, user_uuid)
    if load.running >= B.MAX_RUNNING then
        U.fail(429, "Your PA is still working on " .. load.running .. " questions. Wait for one to finish.")
    end
    if load.hour >= B.MAX_PER_HOUR then U.fail(429, "That's " .. load.hour .. " questions this hour. Try again later.") end
    if over_daily_limit(user_uuid) then
        meter(ns, user_uuid, nil, req.mode, nil, 0, 0, 0, "daily limit reached")
        U.fail(429, require("lib.agent.llm").LIMIT_MESSAGE)
    end
    local role = req.role or "seller_agent"
    local agent_id = nz(role == "manager" and settings.jobshout_manager_agent_id or settings.jobshout_seller_agent_id)
    if not agent_id then U.fail(409, "The PA isn't connected: set the JobShout " .. (role == "manager" and "Manager" or "Seller")
        .. " PA agent id in the Property PA settings") end
    local row = link(ns, settings)
    local JobShout = require("lib.jobshout-client")
    local agent_key = "pa_" .. role
    local context = { role = role, user_ref = user_uuid, workspace_ref = tostring(ns) }
    local inputs = {}
    for k, v in pairs(req.inputs or {}) do inputs[k] = v end
    -- What the server checked always wins over the caller's inputs.
    inputs.mode, inputs.opportunity_id, inputs.interaction_uuid = req.mode, req.opportunity_uuid, req.interaction_uuid
    local skill = B.SKILLS[req.mode]
    local skills = skill and { skill } or nil
    -- One JobShout task per person and role: every turn is a new run on it.
    local prev = U.one([[SELECT jobshout_task_id FROM property_deals_agent_runs WHERE namespace_id = ? AND provider = ?
        AND agent_key = ? AND triggered_by_user_uuid = ? AND jobshout_task_id IS NOT NULL ORDER BY id DESC LIMIT 1]],
        ns, B.PROVIDER, agent_key, user_uuid)
    local res, err, task_id, run_id
    if prev then
        res, err = JobShout.run_task(ns, row, prev.jobshout_task_id, { agent_id = agent_id, prompt = req.message,
            context = context, skill_slugs = skills, inputs = inputs })
        task_id, run_id = prev.jobshout_task_id, res and (res.id or res.run_id)
    else
        res, err = JobShout.launch(ns, row, { agent_id = agent_id, project_id = nz(settings.jobshout_project_id),
            values = { prompt = req.message }, context = context, skill_slugs = skills, inputs = inputs })
        task_id = res and (type(res.task) == "table" and res.task.id or res.task_id)
        run_id = res and res.run_id
    end
    if not res or not run_id then
        -- JobShout's own words stay in the log: they can carry its internals.
        ngx.log(ngx.ERR, "[property_pa] JobShout run not started: ", tostring(err or "no run id"):sub(1, 500))
        U.fail(502, "The PA couldn't be reached. Try again in a minute.")
    end
    local r = db.insert("property_deals_agent_runs", {
        namespace_id = ns, agent_key = agent_key, provider = B.PROVIDER, provider_uuid = row.uuid,
        model = "jobshout:" .. agent_id, status = "running", trigger = "manual",
        input_snapshot = db.raw(db.escape_literal(cjson.encode({ mode = req.mode, role = role, message = req.message,
            opportunity_uuid = req.opportunity_uuid, interaction_uuid = req.interaction_uuid,
            skill = skill or cjson.null })) .. "::jsonb"),
        jobshout_task_id = tostring(task_id or ""), jobshout_run_id = tostring(run_id),
        triggered_by_user_uuid = user_uuid, started_at = db.raw("NOW()"),
    }, { returning = { "uuid" } })[1]
    return B.get(ns, r.uuid, user_uuid)
end

--- The pa_output block at the end of an answer. @return table | nil, error
function B.parse_output(text)
    if type(text) ~= "string" then return nil, "no output" end
    local block = text:match("```pa_output%s*(%b{})%s*```%s*$") or text:match("```pa_output%s*(%b{})")
    if not block then return nil, "the answer has no pa_output block" end
    local ok, out = pcall(cjson.decode, block)
    if not ok or type(out) ~= "table" then return nil, "the pa_output block isn't valid JSON" end
    if out.contract ~= "property-pa.output.v1" or type(out.answer) ~= "string" then
        return nil, "the pa_output block doesn't follow property-pa.output.v1"
    end
    return out
end

--- A pa_output source as an OpsAPI ref (table:uuid[:field]), or nil.
function B.ref(source)
    if type(source) ~= "table" or type(source.id) ~= "string" then return nil end
    if G.parse_ref(source.id) then return source.id end
    local t = B.SOURCE_TABLES[source.type]
    if t and U.is_uuid(source.id) then return t .. ":" .. source.id end
    return nil
end

local function arr(v) return setmetatable(type(v) == "table" and v or {}, cjson.array_mt) end

--- Check a parsed answer. @return result shown to the user
function B.check(ns, out, mode)
    local refs = {}
    for _, s in ipairs(type(out.sources) == "table" and out.sources or {}) do refs[#refs + 1] = B.ref(s) end
    local claims = {}
    if #G.figures(out.answer) > 0 then claims[1] = { text = out.answer, refs = refs } end
    -- Every cited source must exist in this workspace, figures or not.
    local verdict = G.check(ns, { text = out.answer, claims = claims })
    for _, ref in ipairs(refs) do
        if not G.resolve(ns, ref) then
            verdict.ok = false
            table.insert(verdict.violations, { kind = "unknown_ref", ref = ref, message = "source not found in this workspace" })
        end
    end
    -- Authority (P06): the PA coaches with questions; it never recommends paying more. Offers are a person's call.
    local phrase = (mode == "coach" or out.mode == "coach") and require("property_pa.brief").recommends_higher_offer(out.answer)
    if phrase then
        verdict.ok = false
        table.insert(verdict.violations, { kind = "higher_offer", message = "coaching may not recommend a higher offer ('"
            .. phrase .. "'); suggest questions and hand the decision to someone with authority" })
    end
    return verdict
end

--- Why an answer isn't shown, in words a person can act on.
function B.withheld_text(verdict)
    for _, v in ipairs(verdict.violations) do
        if v.kind == "higher_offer" then
            return "The PA's answer suggested paying more. That is a decision for someone with authority, so it isn't "
                .. "shown. Ask the PA for the questions to ask first, or hand it to your manager."
        end
    end
    return "The PA's answer cited something that isn't on record, so it isn't shown. Ask again, or open the record."
end

--- Store a finished run. data = JobShout run (poll) or webhook `data`. Idempotent: a finished run stays as it is.
function B.finish(ns, run, data)
    if run.status ~= "running" then return run end
    local status = tostring(data.status)
    local upd = {
        tokens_out = tonumber(data.total_tokens) or 0, cost_usd = tonumber(data.cost_usd) or 0,
        latency_ms = tonumber(data.latency_ms) or db.NULL, finished_at = db.raw("NOW()"), updated_at = db.raw("NOW()"),
    }
    if nz(data.model_name) then upd.model = (nz(data.model_provider) and (data.model_provider .. ":") or "") .. data.model_name end
    if nz(data.prompt_version) then upd.prompt_version = tostring(data.prompt_version):sub(1, 40) end
    if status == "failed" then
        ngx.log(ngx.WARN, "[property_pa] run ", run.uuid, " failed: ", tostring(nz(data.error_message)):sub(1, 500))
        upd.status, upd.error = "failed", "The PA couldn't finish this one. Try asking again."
    else
        local raw = nz(data.output) or ""
        local out, perr = B.parse_output(raw)
        local result
        if not out then
            result = { grounded = false, contract_ok = false, answer = cjson.null,
                withheld = "The PA's answer couldn't be checked (" .. perr .. "), so it isn't shown.",
                violations = arr({}) }
        else
            local snap = U.json(run.input_snapshot)
            local verdict = B.check(ns, out, type(snap) == "table" and snap.mode or nil)
            result = { contract_ok = true, grounded = verdict.ok, mode = out.mode,
                answer = verdict.ok and out.answer or cjson.null,
                withheld = (not verdict.ok) and B.withheld_text(verdict) or cjson.null,
                violations = verdict.violations, sources = arr(out.sources), unknowns = arr(out.unknowns),
                inferences = arr(out.inferences), actions = arr(out.actions), needs_human = out.needs_human == true }
        end
        upd.status = "succeeded"
        upd.output = db.raw(db.escape_literal(cjson.encode(result)) .. "::jsonb")
        upd.output_draft = raw:sub(1, 60000)
        upd.sources = db.raw(db.escape_literal(cjson.encode(result.sources or arr({}))) .. "::jsonb")
    end
    -- Only a running run is finished (a webhook and a poll may race; the first one wins, and meters it).
    local res = db.update("property_deals_agent_runs", upd, { namespace_id = ns, uuid = run.uuid, status = "running" })
    if (res.affected_rows or 0) > 0 then
        local total = tonumber(data.total_tokens) or 0
        local input = math.min(total, tonumber(data.prompt_tokens or data.input_tokens) or 0)
        local snap = U.json(run.input_snapshot)
        meter(ns, run.triggered_by_user_uuid, run.uuid, type(snap) == "table" and snap.mode or nil,
            upd.model or run.model, input, total - input, tonumber(data.latency_ms) or 0,
            status == "failed" and "the PA run failed" or nil)
    end
    -- What the run wrote while it was running (captures) gets the model and prompt version it really used (P10).
    if upd.model or upd.prompt_version then
        for _, t in ipairs({ "pa_proposed_updates", "pa_field_facts" }) do
            db.query("UPDATE " .. t .. [[ SET model = COALESCE(?, model), prompt_version = COALESCE(prompt_version, ?),
                updated_at = NOW() WHERE namespace_id = ? AND run_ref = ?]], upd.model or db.NULL,
                upd.prompt_version or db.NULL, ns, run.uuid)
        end
    end
    return U.one(B.SELECT .. " WHERE namespace_id = ? AND uuid = ?::uuid", ns, run.uuid)
end

--- Background sweep (jobs/pa_runs.lua): poll runs whose webhook hasn't arrived, and fail runs that never finish.
-- @return { polled, finished, timed_out }
function B.sweep(ns)
    local out = { polled = 0, finished = 0, timed_out = 0 }
    for _, r in ipairs(db.query(B.SELECT .. [[ WHERE namespace_id = ? AND provider = ? AND status = 'running'
        AND started_at < NOW() - INTERVAL '1 minute' ORDER BY started_at LIMIT 50]], ns, B.PROVIDER)) do
        local stale = U.one("SELECT (?::timestamptz < NOW() - make_interval(mins => ?)) AS s", r.started_at, B.TIMEOUT_MINUTES)
        if stale and stale.s then
            db.update("property_deals_agent_runs", { status = "failed", error = "The PA didn't answer within "
                .. B.TIMEOUT_MINUTES .. " minutes", finished_at = db.raw("NOW()"), updated_at = db.raw("NOW()") },
                { namespace_id = ns, uuid = r.uuid, status = "running" })
            out.timed_out = out.timed_out + 1
        else
            local ok, done = pcall(B.poll, ns, r)
            out.polled = out.polled + 1
            if ok and done and done.status ~= "running" then out.finished = out.finished + 1 end
            if not ok then ngx.log(ngx.WARN, "[property_pa] sweep poll: ", tostring(done)) end
        end
    end
    return out
end

--- Poll JobShout once for a running run. @return run row (finished or still running)
function B.poll(ns, run)
    if run.status ~= "running" then return run end
    local row = U.one("SELECT * FROM namespace_ai_providers WHERE namespace_id = ? AND uuid = (SELECT provider_uuid FROM "
        .. "property_deals_agent_runs WHERE uuid = ?::uuid)", ns, run.uuid)
    if not row then return run end
    local r, err = require("lib.jobshout-client").run(ns, row, run.jobshout_run_id)
    if not r then
        ngx.log(ngx.WARN, "[property_pa] JobShout poll: ", tostring(err))
        return run
    end
    local s = tostring(r.status)
    if s ~= "completed" and s ~= "failed" then return run end
    return B.finish(ns, run, r)
end

return B
