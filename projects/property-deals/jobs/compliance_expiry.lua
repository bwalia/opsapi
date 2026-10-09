-- Daily, per workspace: expire passed compliance checks and proofs of funds
-- whose date has gone, and warn (once) about checks expiring soon. A deal
-- whose gate needs an expired check is blocked until someone redoes it.
local root = debug.getinfo(1, "S").source:match("^@(.+)/jobs/[^/]+%.lua$")
if root and not package.path:find(root .. "/?.lua", 1, true) then package.path = root .. "/?.lua;" .. package.path end

return {
    every = "1d",
    at = "05:00",
    run = function(job)
        require("property_deals.compliance").expire(job.namespace_id, job.settings)
    end,
}
