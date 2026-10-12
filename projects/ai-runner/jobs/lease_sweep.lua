-- Every minute, once per deployment (docs/AI_RUNNER.md §22.3, §23.1): open runs whose runner stopped heartbeating
-- (lease_until passed) become lost, queued runs nobody claimed within 24 h and runs nobody approved within 72 h
-- are cancelled, unanswered permission requests expire, and folder locks of ended runs are released. Safe to run
-- twice: every step only touches rows still in the state it changes.
local root = debug.getinfo(1, "S").source:match("^@(.+)/jobs/[^/]+%.lua$")
if root and not package.path:find(root .. "/?.lua", 1, true) then package.path = root .. "/?.lua;" .. package.path end

return {
    every = "1m",
    scope = "global",
    run = function()
        local r = require("ai_runner.runs").sweep()
        if r.lost + r.cancelled + r.locks_released + r.requests_expired > 0 then
            ngx.log(ngx.NOTICE, "[ai_runner] lease sweep: lost=", r.lost, " cancelled=", r.cancelled,
                " locks_released=", r.locks_released, " requests_expired=", r.requests_expired)
        end
    end,
}
