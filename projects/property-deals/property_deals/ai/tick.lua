-- Once a minute per workspace (jobs/agents_tick.lua; POST /engine/run {checks:["agents"]}):
--   1. queued runs whose timer was lost → handed to timers again (never run here: a slow model would
--      hold this job past its lease), within the workspace's concurrency cap
--   2. built-in runs stuck "running" for 15 min → failed, task back to a person
--   3. approved actions stuck "running" for 15 min (the worker died) → failed, so a manager can retry
--   4. JobShout: poll running runs, mirror new JobShout approvals, and mirror
--      decisions made in JobShout's own UI back here (one approval, two systems)
--   5. auto pickup: agents set to start by themselves at a local time, and tasks
--      whose template says agent.auto (started once, when they're first open)
local cjson = require("cjson")
local db = require("lapis.db")
local U = require("property_deals.util")
local Config = require("property_deals.ai.config")
local Approvals = require("property_deals.approvals")

local Tick = {}

local function jobshout_sweep(ns, out)
    local Runner = require("property_deals.ai.runner")
    local JobShout = require("lib.jobshout-client")
    local runs = db.query([[
        SELECT * FROM property_deals_agent_runs
        WHERE namespace_id = ? AND provider = 'jobshout' AND status = 'running' AND jobshout_run_id IS NOT NULL
        ORDER BY created_at LIMIT 50
    ]], ns)
    local mirrored = db.query([[
        SELECT a.*, a.jobshout_provider_uuid AS pu FROM property_deals_approvals a
        WHERE a.namespace_id = ? AND a.status = 'pending' AND a.jobshout_approval_id IS NOT NULL
    ]], ns)
    local providers = {}
    -- (a link deleted since leaves its runs and approvals without one)
    for _, r in ipairs(runs) do if U.is_uuid(r.provider_uuid) then providers[r.provider_uuid] = true end end
    for _, a in ipairs(mirrored) do if U.is_uuid(a.pu) then providers[a.pu] = true end end
    for puuid in pairs(providers) do
        local row = U.one("SELECT * FROM namespace_ai_providers WHERE namespace_id = ? AND uuid = ?", ns, puuid)
        if row then
            local all, err = JobShout.approvals(ns, row, nil)
            if not all then
                ngx.log(ngx.WARN, "[property_deals] JobShout approvals: ", tostring(err))
            else
                local pending_by_exec, by_id = {}, {}
                for _, ja in ipairs(all) do
                    by_id[ja.id] = ja
                    if ja.status == "pending" and ja.execution_id then
                        pending_by_exec[ja.execution_id] = pending_by_exec[ja.execution_id] or {}
                        table.insert(pending_by_exec[ja.execution_id], ja)
                    end
                end
                -- Decided over in JobShout: record it here so nobody is asked twice. Only for an
                -- any-operator approval, by someone other than the requester: manager and two-person
                -- approvals are decided here, where our roles apply.
                for _, a in ipairs(mirrored) do
                    local ja = a.pu == puuid and by_id[a.jobshout_approval_id]
                    local who = ja and ja.decided_by ~= cjson.null and ja.decided_by or nil
                    if ja and (ja.status == "approved" or ja.status == "rejected") and (a.rule ~= "any_operator"
                            or (who and (who == a.requested_by_user_uuid or Approvals.is_agent(ns, who)))) then
                        ngx.log(ngx.NOTICE, "[property_deals] approval ", a.uuid,
                            ": JobShout's decision not taken (rule ", a.rule, "); it must be decided in Property Deals")
                    elseif ja and (ja.status == "approved" or ja.status == "rejected") then
                        local ds = U.json(a.decisions) or {}
                        ds[#ds + 1] = { decision = ja.status == "approved" and "approve" or "reject", by = "jobshout",
                            jobshout_user = ja.decided_by, note = ja.reason, at = ja.decided_at,
                            payload_version = tonumber(a.payload_version), payload_sha256 = a.payload_sha256 }
                        local approved = ja.status == "approved"
                        db.update("property_deals_approvals", {
                            status = approved and "executed" or "rejected", decided_at = db.raw("NOW()"),
                            executed_at = approved and db.raw("NOW()") or nil,
                            execution_result = approved and cjson.encode({ by = "jobshout" }) or nil,
                            decisions = cjson.encode(U.array(ds)), updated_at = db.raw("NOW()"),
                        }, { id = a.id, status = "pending" })
                        if not approved then
                            Approvals.back_to_todo(ns, a.task_uuid ~= db.NULL and a.task_uuid or nil,
                                "Rejected in JobShout: " .. tostring(ja.reason ~= cjson.null and ja.reason or ""), nil)
                        end
                        out.jobshout_decided = out.jobshout_decided + 1
                    end
                end
                for _, r in ipairs(runs) do
                    if r.provider_uuid == puuid then
                        local ok, e = pcall(Runner.poll_jobshout, ns, r, pending_by_exec)
                        if not ok then ngx.log(ngx.ERR, "[property_deals] JobShout poll: ", tostring(e)) end
                        out.jobshout_polled = out.jobshout_polled + 1
                    end
                end
            end
        end
    end
end

--- Never more runs at once than the workspace's cap (ai_max_concurrent_runs): what doesn't fit waits for a
-- later tick. Off altogether with the setting ai_auto_runs.
local function auto_pickup(ns, settings, out)
    if settings and settings.ai_auto_runs == false then return end
    local Runner = require("property_deals.ai.runner")
    local running, queued = Config.busy(ns)
    local room = Config.caps(settings).concurrent - running - queued
    if room <= 0 then return end
    local function start(task_uuid)
        if room > 0 and Runner.start(ns, task_uuid, { trigger = "auto" }) then
            room, out.auto_started = room - 1, out.auto_started + 1
        end
    end
    local tz = settings and settings.timezone or "Europe/London"
    local now = U.one("SELECT to_char(NOW() AT TIME ZONE ?, 'HH24:MI') AS t, (NOW() AT TIME ZONE ?)::date AS d", tz, tz)
    for _, c in ipairs(db.query([[
        SELECT * FROM property_deals_agent_configs
        WHERE namespace_id = ? AND enabled AND auto_pickup AND auto_pickup_at IS NOT NULL AND auto_pickup_at <= ?
          AND last_auto_run_on IS DISTINCT FROM ?::date
    ]], ns, now.t, now.d)) do
        -- Each task once a day; the agent is done for the day once every due task has had its run.
        local fits = room
        local tasks = db.query([[
            SELECT task_uuid FROM property_deals_task_details d
            WHERE namespace_id = ? AND agent_eligible AND agent_key = ? AND pd_status IN ('todo', 'in_progress')
              AND (snoozed_until IS NULL OR snoozed_until < NOW())
              AND NOT EXISTS (SELECT 1 FROM property_deals_agent_runs r WHERE r.namespace_id = d.namespace_id
                  AND r.task_uuid = d.task_uuid AND r.trigger = 'auto'
                  AND (r.created_at AT TIME ZONE ?)::date = ?::date)
            ORDER BY urgency_score DESC LIMIT ?
        ]], ns, c.agent_key, tz, now.d, fits + 1)
        for i = 1, math.min(#tasks, fits) do start(tasks[i].task_uuid) end
        if #tasks <= fits then
            db.query("UPDATE property_deals_agent_configs SET last_auto_run_on = ?::date WHERE id = ?", now.d, c.id)
        end
        if room <= 0 then return end
    end
    -- Template-driven: agent.auto tasks start once, the first time they're open with a clock.
    for _, t in ipairs(db.query([[
        SELECT d.task_uuid FROM property_deals_task_details d
        WHERE d.namespace_id = ? AND d.agent_eligible AND d.pd_status = 'todo'
          AND d.metadata ->> 'agent_auto' = 'true' AND d.sla_started_at IS NOT NULL
          AND NOT EXISTS (SELECT 1 FROM property_deals_agent_runs r WHERE r.task_uuid = d.task_uuid)
        LIMIT ?
    ]], ns, room)) do
        start(t.task_uuid)
    end
end

function Tick.run(ns, settings)
    local Runner = require("property_deals.ai.runner")
    local out = { resumed = 0, timed_out = 0, unstuck = 0, jobshout_polled = 0, jobshout_decided = 0, auto_started = 0 }
    local running = Config.busy(ns)
    for _, r in ipairs(db.query([[
        SELECT uuid FROM property_deals_agent_runs
        WHERE namespace_id = ? AND status = 'queued' AND created_at < NOW() - interval '30 seconds'
        ORDER BY created_at LIMIT ?
    ]], ns, math.max(0, Config.caps(settings).concurrent - running))) do
        if Runner.schedule(ns, r.uuid) then out.resumed = out.resumed + 1 end
    end
    for _, r in ipairs(db.query([[
        UPDATE property_deals_agent_runs SET status = 'failed', error = 'timed out', finished_at = NOW(), updated_at = NOW()
        WHERE namespace_id = ? AND provider = 'builtin' AND status = 'running' AND started_at < NOW() - interval '15 minutes'
        RETURNING task_uuid
    ]], ns)) do
        require("property_deals.approvals").back_to_todo(ns, r.task_uuid ~= db.NULL and r.task_uuid or nil,
            "AI couldn't finish: it timed out.", nil)
        out.timed_out = out.timed_out + 1
    end
    -- A JobShout run that goes quiet for 2 hours (no run id, a status we don't know) gives its task back too.
    -- Quiet = nothing waiting for a person, and no approval of it touched since.
    for _, r in ipairs(db.query([[
        UPDATE property_deals_agent_runs r SET status = 'failed', error = 'timed out', finished_at = NOW(),
            updated_at = NOW()
        WHERE r.namespace_id = ? AND r.provider = 'jobshout' AND r.status IN ('queued', 'running')
          AND NOT EXISTS (SELECT 1 FROM property_deals_approvals a WHERE a.namespace_id = r.namespace_id
                          AND a.agent_run_uuid = r.uuid AND a.status IN ('pending', 'approved'))
          AND GREATEST(COALESCE(r.started_at, r.created_at), COALESCE((SELECT MAX(a.updated_at)
              FROM property_deals_approvals a WHERE a.namespace_id = r.namespace_id AND a.agent_run_uuid = r.uuid),
              r.created_at)) < NOW() - interval '2 hours'
        RETURNING r.task_uuid
    ]], ns)) do
        require("property_deals.approvals").back_to_todo(ns, r.task_uuid ~= db.NULL and r.task_uuid or nil,
            "JobShout didn't finish in 2 hours; run it again or do the task by hand.", nil)
        out.timed_out = out.timed_out + 1
    end
    -- Safe to retry: each send is recorded as it happens (executor steps), so a retry never repeats one.
    out.unstuck = #db.query([[
        UPDATE property_deals_approvals SET status = 'failed', updated_at = NOW(),
            execution_result = '{"error": "The action was interrupted; retry it"}'::jsonb
        WHERE namespace_id = ? AND status IN ('approved', 'failed') AND executed_at IS NULL
          AND execution_result ->> 'running' IS NOT NULL AND updated_at < NOW() - interval '15 minutes'
        RETURNING id
    ]], ns)
    jobshout_sweep(ns, out)
    auto_pickup(ns, settings, out)
    return out
end

return Tick
