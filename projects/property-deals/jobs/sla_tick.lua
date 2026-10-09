-- Every minute, per workspace: SLA warnings / overdue / escalation (property_deals.sla),
-- then deal health, money at risk, predicted completion and task urgency
-- (property_deals.health). Safe to run twice: every step is claimed once.
local root = debug.getinfo(1, "S").source:match("^@(.+)/jobs/[^/]+%.lua$")
if root and not package.path:find(root .. "/?.lua", 1, true) then package.path = root .. "/?.lua;" .. package.path end

return {
    every = "1m",
    run = function(job)
        local stats = require("property_deals.sla").tick(job.namespace_id, job.settings)
        local deals = require("property_deals.health").recompute_workspace(job.namespace_id, job.settings)
        local Metrics = require("property_deals.metrics")
        Metrics.sla(job.namespace_id, stats)
        pcall(Metrics.gauges, job.namespace_id)
        if stats.warned + stats.overdue + stats.escalated > 0 then
            ngx.log(ngx.NOTICE, "[property_deals] sla_tick ns=", job.namespace_id, " warned=", stats.warned,
                " overdue=", stats.overdue, " escalated=", stats.escalated, " deals=", deals)
        end
    end,
}
