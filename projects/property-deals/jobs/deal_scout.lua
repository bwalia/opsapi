-- Daily at 06:00 UTC, per workspace: sync connectors set to sync (sold prices / EPC
-- for the postcodes of active deals and saved-search pins), then re-run every
-- saved search and alert owners about new / reduced / stale / cash-only homes.
local root = debug.getinfo(1, "S").source:match("^@(.+)/jobs/[^/]+%.lua$")
if root and not package.path:find(root .. "/?.lua", 1, true) then package.path = root .. "/?.lua;" .. package.path end

return {
    every = "1d",
    at = "06:00",
    run = function(job)
        local Scout = require("property_deals.scout")
        local synced = Scout.sync(job.namespace_id)
        local out = Scout.run(job.namespace_id, job.settings)
        if out.alerts > 0 or synced.stored > 0 then
            ngx.log(ngx.NOTICE, "[property_deals] deal scout ns=", job.namespace_id, " searches=", out.searches,
                " alerts=", out.alerts, " synced_records=", synced.stored)
        end
    end,
}
