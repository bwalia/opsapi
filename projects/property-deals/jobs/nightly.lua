-- Nightly at 02:30 UTC, per workspace:
--   * supplier speed: measured turnaround and on-time % onto the directory (last 12 months of bookings)
--   * retention: email bodies and AI run inputs/drafts older than the workspace's settings are removed
--     (the facts stay: who, when, matched deal, outcome, tokens, cost); stale market data is deleted
local root = debug.getinfo(1, "S").source:match("^@(.+)/jobs/[^/]+%.lua$")
if root and not package.path:find(root .. "/?.lua", 1, true) then package.path = root .. "/?.lua;" .. package.path end

return {
    every = "1d",
    at = "02:30",
    run = function(job)
        local out = require("property_deals.retention").run(job.namespace_id, job.settings)
        out.suppliers = require("property_deals.reports").update_supplier_stats(job.namespace_id)
        if out.suppliers + out.inbound + out.agent_runs + out.market > 0 then
            ngx.log(ngx.NOTICE, "[property_deals] nightly ns=", job.namespace_id, " suppliers=", out.suppliers,
                " inbound_redacted=", out.inbound, " runs_redacted=", out.agent_runs, " market_deleted=", out.market)
        end
    end,
}
