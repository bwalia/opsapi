-- Every 5 minutes, per workspace: read new mail from the workspace's connectors
-- (IMAP / Gmail / Microsoft 365), match it to deals, mark chases replied.
local root = debug.getinfo(1, "S").source:match("^@(.+)/jobs/[^/]+%.lua$")
if root and not package.path:find(root .. "/?.lua", 1, true) then package.path = root .. "/?.lua;" .. package.path end

return {
    every = "5m",
    run = function(job)
        local out = require("property_deals.mail").sync_all(job.namespace_id)
        if out.stored > 0 or out.errors > 0 then
            ngx.log(ngx.NOTICE, "[property_deals] mail ns=", job.namespace_id, " stored=", out.stored, " errors=", out.errors)
        end
    end,
}
