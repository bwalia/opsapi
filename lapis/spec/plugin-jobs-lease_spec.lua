--[[
    Spec: a plugin job that runs longer than its lease (helper/plugin-jobs.lua,
    LEASE_SECONDS) is never claimed twice: while the worker holds a run it
    renews the lease every LEASE_SECONDS / 3, only while the lease is still
    the one it set (compare-and-set on locked_until), and stops once the run
    is finished.

    Run from the repo root (what CI does):
        luajit lapis/spec/plugin-jobs-lease_spec.lua
]]

package.path = "./?.lua;lapis/?.lua;" .. package.path

local failures = 0
local function check(name, ok, detail)
    if ok then
        print("  ok   - " .. name)
    else
        failures = failures + 1
        print("  FAIL - " .. name .. (detail and ("  (" .. tostring(detail) .. ")") or ""))
    end
end

-- Timers: tick (every) and the heartbeat (at) are captured and fired by hand.
local tick, timers, delays = nil, {}, {}
ngx = { log = function() end, ERR = 3, WARN = 4, time = os.time, now = os.time, update_time = function() end, -- luacheck: ignore 111
    worker = { id = function() return 1 end },
    timer = {
        every = function(_, fn) tick = fn return true end,
        at = function(delay, fn)
            timers[#timers + 1], delays[#delays + 1] = { fn = fn }, delay
            return true
        end,
    } }
local function fire()
    local t = table.remove(timers, 1)
    if t then t.fn(false) end
    return t
end

-- plugin_jobs: one due row; leases as strings, like pgmoon returns timestamptz.
local claimed_once, renewals, finished, lease_n = false, {}, false, 1
local stolen = false
package.loaded["lapis.db"] = {
    NULL = setmetatable({}, {}),
    escape_literal = function(s) return "'" .. s .. "'" end,
    query = function(sql, a, b)
        if sql:find("WHERE id IN (", 1, true) then -- claim
            if claimed_once then return {} end
            claimed_once = true
            return { { id = 42, job = "demo.long", namespace_id = 7, locked_until = "lease-1" } }
        elseif sql:find("AND locked_until = ?::timestamptz", 1, true) then -- heartbeat
            renewals[#renewals + 1] = { id = a, mine = b }
            if stolen or b ~= "lease-" .. lease_n then return {} end
            lease_n = lease_n + 1
            return { { locked_until = "lease-" .. lease_n } }
        elseif sql:find("SET locked_until = NULL", 1, true) then
            finished = true
        end
        return {}
    end,
}
package.loaded["helper.plugin-events"] = { resetTransaction = function() return false end,
    releaseConnection = function() end }

-- One plugin with one job; its run "takes" two heartbeats' worth of time.
local tmp = os.tmpname()
os.remove(tmp)
os.execute("mkdir -p " .. tmp .. "/jobs")
local f = assert(io.open(tmp .. "/jobs/long.lua", "w"))
f:write('return { every = "1h", run = function() __during_run() end }')
f:close()
package.loaded["helper.project-loader"] = {
    discover = function() return { { manifest_path = tmp .. "/project.lua", path = tmp } } end,
    loadManifest = function() return { code = "demo", enabled = true, path = tmp } end,
    isReservedCode = function() return false end,
    listDir = function(dir) return dir == tmp .. "/jobs" and { "long.lua" } or {} end,
}

local PluginJobs = require("helper.plugin-jobs")
local beats_during_run = 0
__during_run = function() -- luacheck: ignore 111
    -- LEASE_SECONDS / 3 pass, twice, while the job is still running.
    for _ = 1, 2 do
        local t = fire()
        if t then beats_during_run = beats_during_run + 1 end
    end
end

PluginJobs.start(tmp)
check("the scheduler started", tick ~= nil)
tick(false)
check("the lease is renewed while the run is still going", beats_during_run == 2 and #renewals == 2,
    #renewals)
check("every LEASE_SECONDS / 3", #delays >= 2 and delays[1] == 300 and delays[2] == 300, delays[1])
check("compare-and-set: each renewal names the lease it holds", renewals[1].id == 42
    and renewals[1].mine == "lease-1" and renewals[2].mine == "lease-2")
check("the run finished normally", finished)
local before = #renewals
fire() -- the next beat after the run: nothing held, it stops
check("after the run: no more renewals, no more timers", #renewals == before and #timers == 0)

print("a lease another worker took over is left alone:")
claimed_once, renewals, finished, lease_n, stolen = false, {}, false, 1, true
beats_during_run = 0
tick(false)
check("one failed compare-and-set and it stops renewing that run", #renewals == 1 and beats_during_run >= 1,
    #renewals)

os.execute("rm -rf " .. tmp)
print(failures == 0 and "\nAll checks passed." or ("\n" .. failures .. " check(s) FAILED."))
os.exit(failures == 0 and 0 or 1)
