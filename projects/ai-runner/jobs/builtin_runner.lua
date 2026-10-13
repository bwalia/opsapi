-- Every minute, once per deployment (docs/AI_RUNNER.md §28.2): start working through queued built-in runs that
-- nothing picked up yet (a start or approval kicks the runner at once; this catches one made while a pod restarted,
-- or that waited for a free slot). The runs themselves go on in the background, not in this job.
local root = debug.getinfo(1, "S").source:match("^@(.+)/jobs/[^/]+%.lua$")
if root and not package.path:find(root .. "/?.lua", 1, true) then package.path = root .. "/?.lua;" .. package.path end

return {
    every = "1m",
    scope = "global",
    run = function()
        require("ai_runner.builtin").kick()
    end,
}
