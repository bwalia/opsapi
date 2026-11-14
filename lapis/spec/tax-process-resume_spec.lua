--[[
    Spec: statement processing survives a restart.

    The worker runs in one nginx worker's memory. A deploy that restarted the pods
    seven minutes into a 12-statement upload left one statement at CLASSIFYING and ten
    at QUEUED for good. Now a job heartbeats its statements, and a status poll claims
    any that went stale and starts them again, with the chat and profile they had.

    From the repo root: luajit lapis/spec/tax-process-resume_spec.lua
]]

package.path = "lapis/?.lua;lapis/?/init.lua;" .. package.path

local failures = 0
local function check(name, ok, detail)
    if ok then print("  ok   - " .. name) else
        failures = failures + 1
        print("  FAIL - " .. name .. (detail and ("  (" .. tostring(detail) .. ")") or ""))
    end
end

local timers = {}
_G.ngx = setmetatable({
    var = { server_port = "80" }, ctx = {}, log = function() end, ERR = 3, WARN = 5, INFO = 7, time = os.time,
    timer = { at = function(delay, fn, job) timers[#timers + 1] = { delay = delay, fn = fn, job = job }; return true end },
}, { __index = function() return function() end end })

local queries, claim_rows, claim_fails_on_column = {}, {}, false
package.loaded["lapis.db"] = {
    query = function(sql, ...)
        queries[#queries + 1] = { sql = sql, args = { ... } }
        if sql:find("UPDATE tax_statements SET processing_status = 'QUEUED'", 1, true) then
            if claim_fails_on_column and sql:find("processing_job", 1, true) then
                error('column "processing_job" does not exist')
            end
            return claim_rows
        end
        if sql:find("FROM tax_agent_sessions", 1, true) then
            return { { id = 42, namespace_id = 1, user_id = 7 } }
        end
        return {}
    end,
    select = function() return {} end,
    update = function() end,
    raw = function(x) return x end, escape_literal = function(x) return "'" .. tostring(x) .. "'" end, NULL = {},
}
package.loaded["resty.http"] = { new = function() return {} end }
package.loaded["middleware.auth"] = { requireAuth = function(f) return f end }
package.loaded["helper.jwt-helper"] = {
    verifyToken = function() return { valid = true, payload = { userinfo = { uuid = "u-1" } } } end,
    reissue = function() return "fresh" end,
}
local ok_cjson, cjson = pcall(require, "cjson")
if not ok_cjson then
    cjson = { encode = function() return "{}" end, decode = function(s)
        local t = {}
        for k, v in tostring(s):gmatch('"([%w_]+)":%s*"?([%w_]+)"?') do t[k] = tonumber(v) or v end
        return t
    end }
    package.loaded["cjson"] = cjson
end

local route = require("routes.tax-process")
local resume = route._resume_orphans
check("module exposes resume_orphans for tests", type(resume) == "function")
local self = { req = { headers = { authorization = "Bearer user.jwt" } }, params = {} }

print("nothing stale")
claim_rows = {}
check("returns 0", resume(self, 7) == 0)
check("starts no job", #timers == 0)
local claim = queries[1] and queries[1].sql or ""
check("claims only this user's working statements", claim:find("WHERE user_id = ?", 1, true)
    and claim:find("('QUEUED','EXTRACTING','CLASSIFYING')", 1, true) ~= nil, claim)
check("only ones untouched for STALE_SECS", claim:find("updated_at < NOW() - (? * INTERVAL '1 second')", 1, true) ~= nil)
check("claim is one atomic UPDATE ... RETURNING", claim:find("^UPDATE") ~= nil and claim:find("RETURNING", 1, true) ~= nil)
check("stale threshold is 5 minutes", queries[1] and queries[1].args[2] == 300)

print("a restart left 3 statements behind (one chat, landlord)")
queries, timers = {}, {}
local pj = '{"session_id":42,"profile_type":"landlord"}'
claim_rows = {
    { id = 12, uuid = "c", file_name = "jun.pdf", processing_job = pj },
    { id = 10, uuid = "a", file_name = "apr.pdf", processing_job = pj },
    { id = 11, uuid = "b", file_name = "may.pdf", processing_job = pj },
}
check("returns 3", resume(self, 7) == 3)
check("starts exactly one job", #timers == 1, #timers)
local job = timers[1] and timers[1].job or {}
check("job keeps upload order", job.statements and job.statements[1].uuid == "a" and job.statements[3].uuid == "c")
check("job keeps the landlord profile", job.profile_type == "landlord", job.profile_type)
check("job reports back to the same chat", job.session and job.session.id == 42)
check("job runs as the polling user (fresh JWT identity)", job.jwt_payload and job.jwt_payload.userinfo.uuid == "u-1")
local noted = false
for _, q in ipairs(queries) do if q.sql:find("INSERT INTO tax_agent_messages", 1, true) then noted = true end end
check("tells the chat it picked the work back up", noted)

print("two chats -> two jobs")
queries, timers = {}, {}
claim_rows = {
    { id = 1, uuid = "x", processing_job = pj },
    { id = 2, uuid = "y", processing_job = '{"profile_type":"sole_trader"}' },
}
resume(self, 7)
check("one job per chat/profile", #timers == 2, #timers)

print("before the migration has run")
queries, timers = {}, {}
claim_fails_on_column = true
claim_rows = { { id = 5, uuid = "z" } }
check("still resumes without processing_job", resume(self, 7) == 1 and #timers == 1)
check("retry drops the column", queries[2] and not queries[2].sql:find("processing_job", 1, true))
claim_fails_on_column = false

print("wiring")
local mounted = {}
pcall(route, setmetatable({}, { __index = function(_, m) return function(_, p, h) mounted[m .. " " .. p] = h end end }))
check("routes mount", mounted["post /api/v2/tax/statements/process"] ~= nil
    and mounted["get /api/v2/tax/statements/process-status"] ~= nil)
local h = io.open("lapis/routes/tax-process.lua"); local src = h:read("*a"); h:close()
check("worker schedules a heartbeat", src:find("ngx.timer.at(HEARTBEAT_SECS, heartbeat, job)", 1, true) ~= nil)
check("job is marked done so the heartbeat stops", src:find("job.done = true", 1, true) ~= nil)
check("status poll resumes orphans", src:find("resume_orphans(self, user_id)\n        local rows", 1, true) ~= nil)
check("upload saves the resume context", src:find("SET processing_job = ?::jsonb", 1, true) ~= nil)

print(failures == 0 and "\nALL PASS" or ("\n" .. failures .. " FAILED"))
os.exit(failures == 0 and 0 or 1)
