-- The AI layer's API (SPEC §3.5). Providers and their keys are core:
-- /api/v2/namespace/ai-providers. Here:
--   GET  /ai/agents                       the catalogue + this workspace's settings per agent
--   PUT  /ai/agents/:key                  { enabled?, route? builtin|jobshout, jobshout_provider_uuid?, jobshout_agent_id?,
--                                           jobshout_project_id?, fallback_to_builtin?, local_only?, approval_rule?,
--                                           auto_pickup?, auto_pickup_at? "HH:MM" }
--   GET  /ai/routes                       model chain per job type (classify, extract, draft, plan, chat, summarise)
--   PUT  /ai/routes/:job_type             { chain: [{ provider_uuid, model? }], local_only?, max_tokens? }
--   GET  /ai/usage?days=30                spend today / in the window, by agent; caps
--   POST /tasks/:id/agent-run             "Let AI do it" → 202 with the run (poll GET /agent-runs/:id)
--   POST /agent-runs/:id/cancel           stop a queued/running run; the task goes back to a person
local root = debug.getinfo(1, "S").source:match("^@(.+)/api/[^/]+%.lua$")
if root and not package.path:find(root .. "/?.lua", 1, true) then package.path = root .. "/?.lua;" .. package.path end

local sdk = require("helper.plugin-sdk")
local db = require("lapis.db")
local U = require("property_deals.util")
local Config = require("property_deals.ai.config")

return function(app)
    app:get("/ai/agents", sdk.handler({ permission = "property_deals_ai.read" }, function(self)
        return sdk.ok(Config.agents(sdk.namespace_id(self)))
    end))

    app:put("/ai/agents/:key", sdk.handler({ permission = "property_deals_settings.update" }, U.guard(function(self)
        local body, err = sdk.body(self)
        if not body then return sdk.error(400, err) end
        local row, errors = Config.save_agent(sdk.namespace_id(self), self.params.key, body)
        if not row then return sdk.error(422, "Validation failed", errors) end
        row.id, row.namespace_id = nil, nil
        return sdk.ok(row)
    end)))

    app:get("/ai/routes", sdk.handler({ permission = "property_deals_ai.read" }, function(self)
        return sdk.ok(Config.routes(sdk.namespace_id(self)), { job_types = U.array(Config.JOB_TYPES) })
    end))

    app:put("/ai/routes/:job_type", sdk.handler({ permission = "property_deals_settings.update" }, U.guard(function(self)
        local body, err = sdk.body(self)
        if not body then return sdk.error(400, err) end
        local row, errors = Config.save_route(sdk.namespace_id(self), self.params.job_type, body)
        if not row then return sdk.error(422, "Validation failed", errors) end
        return sdk.ok(row)
    end)))

    app:get("/ai/usage", sdk.handler({ permission = "property_deals_ai.read" }, function(self)
        local ns = sdk.namespace_id(self)
        local days = math.max(1, math.min(366, tonumber(self.params.days) or 30))
        local by_agent = db.query([[
            SELECT agent_key, COUNT(*)::int AS runs, COUNT(*) FILTER (WHERE status = 'failed')::int AS failed,
                   COALESCE(SUM(tokens_in), 0)::int AS tokens_in, COALESCE(SUM(tokens_out), 0)::int AS tokens_out,
                   COALESCE(SUM(cost_usd), 0)::float AS cost_usd, ROUND(AVG(latency_ms))::int AS avg_latency_ms
            FROM property_deals_agent_runs WHERE namespace_id = ? AND created_at >= NOW() - make_interval(days => ?)
            GROUP BY agent_key ORDER BY cost_usd DESC
        ]], ns, days)
        local caps = Config.caps(sdk.settings(self))
        local total = 0
        for _, r in ipairs(by_agent) do total = total + (tonumber(r.cost_usd) or 0) end
        return sdk.ok({ days = days, spent_today_usd = Config.spent_today(ns), spent_window_usd = total,
            cap_day_usd = caps.day, cap_run_usd = caps.run, by_agent = sdk.array(by_agent) })
    end))

    app:post("/tasks/:id/agent-run", sdk.handler({ permission = "property_deals_ai.create" }, U.guard(function(self)
        local body = sdk.body(self) or {}
        local ns = sdk.namespace_id(self)
        local run, err, status = require("property_deals.ai.runner").start(ns, self.params.id, {
            actor = sdk.user(self).uuid, trigger = "manual",
            retry_note = type(body.note) == "string" and body.note ~= "" and body.note or nil,
        })
        if not run then return sdk.error(status or 422, err) end
        return { status = 202, json = { success = true, data = run } }
    end)))

    app:post("/agent-runs/:id/cancel", sdk.handler({ permission = "property_deals_ai.update" }, U.guard(function(self)
        local ns = sdk.namespace_id(self)
        local run = U.is_uuid(self.params.id) and U.one([[
            UPDATE property_deals_agent_runs SET status = 'cancelled', finished_at = NOW(), updated_at = NOW(),
                error = 'cancelled by a person'
            WHERE namespace_id = ? AND uuid = ? AND status IN ('queued', 'running') RETURNING *
        ]], ns, self.params.id)
        if not run then return sdk.error(409, "Only a queued or running run can be cancelled") end
        if run.task_uuid ~= db.NULL then
            local t = require("property_deals.tasks").get(ns, run.task_uuid)
            if t and t.pd_status == "agent_running" then
                require("property_deals.tasks").update(ns, run.task_uuid, { pd_status = "todo" }, sdk.user(self).uuid)
            end
        end
        return sdk.ok(run)
    end)))
end
