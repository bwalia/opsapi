-- Daily at 07:00 UTC, per workspace: the Companies House watch (news about leads with a company number or
-- officer id) and, when areas are set, new property companies in those areas as new leads.
local root = debug.getinfo(1, "S").source:match("^@(.+)/jobs/[^/]+%.lua$")
if root and not package.path:find(root .. "/?.lua", 1, true) then package.path = root .. "/?.lua;" .. package.path end

return {
    every = "1d",
    at = "07:00",
    run = function(job)
        local S = require("property_deals.signals")
        local w = S.watch(job.namespace_id, job.settings)
        local n = S.new_companies(job.namespace_id, job.settings)
        if w.signals > 0 or n.leads > 0 or w.errors > 0 then
            ngx.log(ngx.NOTICE, "[property_deals] lead signals ns=", job.namespace_id, " leads=", w.leads, " signals=",
                w.signals, " errors=", w.errors, " new_company_leads=", n.leads)
        end
    end,
}
