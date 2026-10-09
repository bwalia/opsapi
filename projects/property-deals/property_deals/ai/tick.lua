-- Once a minute per workspace (jobs/agents_tick.lua; POST /engine/run {checks:["agents"]}):
--   1. queued runs whose timer was lost → run them
--   2. built-in runs stuck "running" for 15 min → failed, task back to a person
--   3. JobShout: poll running runs, mirror new JobShout approvals, and mirror
--      decisions made in JobShout's own UI back here (one approval, two systems)
--   4. auto pickup: agents set to start by themselves at a local time, and tasks
--      whose template says agent.auto (started once, when they're first open)
local cjson = require("cjson")
local db = require("lapis.db")
local U = require("property_deals.util")

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
    for _, r in ipairs(runs) do providers[r.provider_uuid] = true end
    for _, a in ipairs(mirrored) do providers[a.pu] = true end
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
                -- Decided over in JobShout: record it here so nobody is asked twice.
                for _, a in ipairs(mirrored) do
                    local ja = a.pu == puuid and by_id[a.jobshout_approval_id]
                    if ja and (ja.status == "approved" or ja.status == "rejected") then
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
                            require("property_deals.approvals").back_to_todo(ns, a.task_uuid ~= db.NULL and a.task_uuid or nil,
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

local function auto_pickup(ns, settings, out)
    local Runner = require("property_deals.ai.runner")
    local tz = settings and settings.timezone or "Europe/London"
    local now = U.one("SELECT to_char(NOW() AT TIME ZONE ?, 'HH24:MI') AS t, (NOW() AT TIME ZONE ?)::date AS d", tz, tz)
    for _, c in ipairs(db.query([[
        SELECT * FROM property_deals_agent_configs
        WHERE namespace_id = ? AND enabled AND auto_pickup AND auto_pickup_at IS NOT NULL AND auto_pickup_at <= ?
          AND last_auto_run_on IS DISTINCT FROM ?::date
    ]], ns, now.t, now.d)) do
        local claimed = db.query([[UPDATE property_deals_agent_configs SET last_auto_run_on = ?::date
            WHERE id = ? AND last_auto_run_on IS DISTINCT FROM ?::date RETURNING id]], now.d, c.id, now.d)[1]
        if claimed then
            for _, t in ipairs(db.query([[
                SELECT task_uuid FROM property_deals_task_details
                WHERE namespace_id = ? AND agent_eligible AND agent_key = ? AND pd_status IN ('todo', 'in_progress')
                  AND (snoozed_until IS NULL OR snoozed_until < NOW()) ORDER BY urgency_score DESC LIMIT 50
            ]], ns, c.agent_key)) do
                if Runner.start(ns, t.task_uuid, { trigger = "auto" }) then out.auto_started = out.auto_started + 1 end
            end
        end
    end
    -- Template-driven: agent.auto tasks start once, the first time they're open with a clock.
    for _, t in ipairs(db.query([[
        SELECT d.task_uuid FROM property_deals_task_details d
        WHERE d.namespace_id = ? AND d.agent_eligible AND d.pd_status = 'todo'
          AND d.metadata ->> 'agent_auto' = 'true' AND d.sla_started_at IS NOT NULL
          AND NOT EXISTS (SELECT 1 FROM property_deals_agent_runs r WHERE r.task_uuid = d.task_uuid)
        LIMIT 50
    ]], ns)) do
        if Runner.start(ns, t.task_uuid, { trigger = "auto" }) then out.auto_started = out.auto_started + 1 end
    end
end

function Tick.run(ns, settings)
    local Runner = require("property_deals.ai.runner")
    local out = { resumed = 0, timed_out = 0, jobshout_polled = 0, jobshout_decided = 0, auto_started = 0 }
    for _, r in ipairs(db.query([[
        SELECT uuid FROM property_deals_agent_runs
        WHERE namespace_id = ? AND status = 'queued' AND created_at < NOW() - interval '30 seconds' LIMIT 20
    ]], ns)) do
        Runner.execute(ns, r.uuid)
        out.resumed = out.resumed + 1
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
    jobshout_sweep(ns, out)
    auto_pickup(ns, settings, out)
    return out
end

return Tick
