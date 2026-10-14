--[[
    ATS — retention (docs/plans/PROMPT_ATS_INTERVIEWS.md §7). Deletes interviews
    and candidates past their delete_after, and old webhook ids. Runs every 6
    hours on worker 0 of every pod; an advisory lock lets one pod work at a time.
    POST /api/v2/ats/admin/purge runs the same function now.
]]

local Retention = {}

local INTERVAL = 6 * 3600

local function run(premature)
    if premature then return end
    local ok, err = pcall(function()
        local db = require("lapis.db")
        db.query("BEGIN")
        local locked = db.query("SELECT pg_try_advisory_xact_lock(hashtext('opsapi.ats.retention')) AS l")[1].l
        local good, res = true, nil
        if locked then good, res = pcall(require("queries.AtsInterviewQueries").purge) end
        db.query(good and "COMMIT" or "ROLLBACK")
        if not good then error(res) end
        if res and (res.interviews > 0 or res.candidates > 0) then
            ngx.log(ngx.NOTICE, "[ats-retention] deleted ", res.interviews, " interviews, ", res.candidates, " candidates")
        end
    end)
    if not ok then ngx.log(ngx.ERR, "[ats-retention] ", tostring(err)) end
end

function Retention.start()
    if ngx.worker.id() ~= 0 then return end
    if not require("helper.project-config").isFeatureEnabled("ats") then return end
    ngx.timer.at(60, run)
    ngx.timer.every(INTERVAL, run)
end

return Retention
