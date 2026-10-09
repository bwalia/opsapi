-- Every minute, per workspace: resume lost agent runs, time out stuck ones,
-- poll JobShout (runs + approvals, both ways), start agents set to auto pickup.
local root = debug.getinfo(1, "S").source:match("^@(.+)/jobs/[^/]+%.lua$")
if root and not package.path:find(root .. "/?.lua", 1, true) then package.path = root .. "/?.lua;" .. package.path end

return {
    every = "1m",
    run = function(job)
        local out = require("property_deals.ai.tick").run(job.namespace_id, job.settings)
        if out.resumed + out.timed_out + out.jobshout_decided + out.auto_started > 0 then
            ngx.log(ngx.NOTICE, "[property_deals] agents ns=", job.namespace_id, " resumed=", out.resumed,
                " timed_out=", out.timed_out, " jobshout_decided=", out.jobshout_decided, " auto=", out.auto_started)
        end
    end,
}
