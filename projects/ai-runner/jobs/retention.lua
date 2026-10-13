-- Daily, per workspace (docs/AI_RUNNER.md §24.7): runs finished more than the workspace's retention_days ago lose
-- their log events, turn texts and request inputs (the run row, summary and usage stay), and sessions of revoked
-- runners are deleted. Safe to run twice: it only touches what is still there.
local root = debug.getinfo(1, "S").source:match("^@(.+)/jobs/[^/]+%.lua$")
if root and not package.path:find(root .. "/?.lua", 1, true) then package.path = root .. "/?.lua;" .. package.path end

return {
    every = "1d",
    run = function(job)
        local r = require("ai_runner.runs").retention(job.namespace_id)
        if r.events + r.turns + r.requests + r.sessions > 0 then
            ngx.log(ngx.NOTICE, "[ai_runner] retention (namespace ", job.namespace_id, "): events=", r.events,
                " turns=", r.turns, " requests=", r.requests, " sessions=", r.sessions)
        end
        return r
    end,
}
