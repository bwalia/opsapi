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

local timers, all_timers = {}, {}
_G.ngx = setmetatable({
    var = { server_port = "80" }, ctx = {}, log = function() end, ERR = 3, WARN = 5, INFO = 7, time = os.time,
    timer = { at = function(delay, fn, job)
        local t = { delay = delay, fn = fn, job = job }
        timers[#timers + 1] = t
        all_timers[#all_timers + 1] = t
        return true
    end },
}, { __index = function() return function() end end })
-- End every job started so far (as nginx would on shutdown), freeing the worker's slots.
local function end_all_jobs()
    for _, t in ipairs(all_timers) do
        if t.delay == 0 and not t.ended then t.ended = true; t.fn(true, t.job) end
    end
end

local queries, claim_rows, claim_fails_on_column = {}, {}, false
package.loaded["lapis.db"] = {
    query = function(sql, ...)
        queries[#queries + 1] = { sql = sql, args = { ... } }
        if sql:find("^UPDATE tax_statements%s+SET processing_status") and sql:find("RETURNING", 1, true) then
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
    and claim:find("('QUEUED','EXTRACTING','CLASSIFYING','PROCESSING')", 1, true) ~= nil, claim)
check("only ones untouched for STALE_SECS", claim:find("updated_at < NOW() - (? * INTERVAL '1 second')", 1, true) ~= nil)
check("claim is one atomic UPDATE ... RETURNING", claim:find("^UPDATE") ~= nil and claim:find("RETURNING", 1, true) ~= nil)
local cargs = queries[1] and queries[1].args or {}
check("stale threshold is 5 minutes", cargs[#cargs] == 300, cargs[#cargs])
check("counts the restart in processing_job.resumes",
    claim:find("jsonb_build_object('resumes', COALESCE((processing_job->>'resumes')::int, 0) + 1)", 1, true) ~= nil)
check("gives up (ERROR + message) after 3 restarts", claim:find("THEN 'ERROR' ELSE 'QUEUED'", 1, true) ~= nil
    and cargs[1] == 3 and tostring(cargs[3]):find("set aside", 1, true) ~= nil)

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

print("a statement that keeps killing its worker is set aside")
queries, timers = {}, {}
claim_rows = {
    { id = 20, uuid = "bad", file_name = "huge.pdf", processing_job = '{"session_id":42,"resumes":4}',
      processing_status = "ERROR" },
    { id = 21, uuid = "fine", file_name = "may.pdf", processing_job = '{"session_id":42,"resumes":1}',
      processing_status = "QUEUED" },
}
check("only the one still going is resumed", resume(self, 7) == 1)
check("one job, without the given-up statement", #timers == 1 and #timers[1].job.statements == 1
    and timers[1].job.statements[1].uuid == "fine")
local told = false
for _, q in ipairs(queries) do
    if q.sql:find("INSERT INTO tax_agent_messages", 1, true) and tostring(q.args[5]):find("huge.pdf", 1, true) then
        told = true
    end
end
check("the chat says which file was set aside", told)

print("a PROCESSING statement (extract died mid-run) is picked up too")
queries, timers = {}, {}
claim_rows = { { id = 30, uuid = "p", file_name = "jul.pdf", processing_job = '{"session_id":42}',
    processing_status = "QUEUED" } }
check("resumed", resume(self, 7) == 1 and #timers == 1)

print("this worker is full: orphans wait for the next poll")
end_all_jobs()
timers = {}
local started = 0
for i = 1, 40 do
    queries = {}
    claim_rows = { { id = 100 + i, uuid = "s" .. i, processing_job = '{"profile_type":"p' .. i .. '"}',
        processing_status = "QUEUED" } }
    if resume(self, 7) == 1 then started = started + 1 end
end
check("no more than 32 jobs at once in a worker", started == 32, started)
check("a full worker doesn't even claim (the restart isn't counted)", #queries == 0)
timers[1].ended = true
timers[1].fn(true, timers[1].job) -- that job ends
queries = {}
check("room again once a job ends", resume(self, 7) == 1)
end_all_jobs()

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
check("upload saves the resume context (and resets the count)",
    src:find("SET processing_job = ?::jsonb, error_message = NULL", 1, true) ~= nil)
local function read(p) local f = io.open(p); local s = f:read("*a"); f:close(); return s end
local ext, cls = read("lapis/routes/tax-extract.lua"), read("lapis/routes/tax-classify.lua")
check("manual extract heartbeats while it runs", ext:find("TaxProcess.keep_alive(statement_id)", 1, true) ~= nil
    and ext:find("stop()", 1, true) ~= nil)
check("a throwing extract can't leave PROCESSING behind",
    ext:find("pcall(Extraction.extract,", 1, true) ~= nil)
check("manual classify heartbeats while it runs", cls:find("TaxProcess.keep_alive(statement_id)", 1, true) ~= nil)

print("keep_alive")
timers = {}
local stop = route.keep_alive(55)
check("schedules a heartbeat", #timers == 1 and timers[1].delay == 60)
queries = {}
timers[1].fn(false, timers[1].job)
check("touches the statement while it's in a working state", queries[1]
    and queries[1].sql:find("WHERE id IN (55) AND processing_status IN", 1, true) ~= nil, queries[1] and queries[1].sql)
stop()
queries, timers = {}, { timers[2] }
timers[1].fn(false, timers[1].job)
check("stops once the request is done", #queries == 0)

print(failures == 0 and "\nALL PASS" or ("\n" .. failures .. " FAILED"))
os.exit(failures == 0 and 0 or 1)
