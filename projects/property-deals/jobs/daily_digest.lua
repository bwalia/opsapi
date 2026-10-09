-- Every 15 minutes, per workspace: once the workspace's local digest_time has
-- passed, send each person today's digest (once per local day, see digest_log).
local root = debug.getinfo(1, "S").source:match("^@(.+)/jobs/[^/]+%.lua$")
if root and not package.path:find(root .. "/?.lua", 1, true) then package.path = root .. "/?.lua;" .. package.path end

return {
    every = "15m",
    run = function(job)
        local sent = require("property_deals.digest").run(job.namespace_id, job.settings)
        if sent > 0 then
            ngx.log(ngx.NOTICE, "[property_deals] daily digest sent to ", sent, " people in ns=", job.namespace_id)
        end
    end,
}
