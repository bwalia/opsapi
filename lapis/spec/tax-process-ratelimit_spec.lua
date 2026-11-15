--[[
    Spec: the statement worker waits out a rate limit instead of failing the statement.

    /tax/classify allows 5 calls a minute per client IP, and the worker's internal calls
    all come from 127.0.0.1. Once payees learned from an earlier year skip the model,
    classify returns in under a second, so a year of 12 statements hit the limit: five
    finished and seven were marked ERROR ("classify HTTP 429" / "extract HTTP 429").
    The worker now sleeps for Retry-After and tries again, with a fresh token each time.

    From the repo root: luajit lapis/spec/tax-process-ratelimit_spec.lua
]]

package.path = "lapis/?.lua;lapis/?/init.lua;" .. package.path

local failures = 0
local function check(name, ok, detail)
    if ok then print("  ok   - " .. name) else
        failures = failures + 1
        print("  FAIL - " .. name .. (detail and ("  (" .. tostring(detail) .. ")") or ""))
    end
end

local sleeps = {}
_G.ngx = setmetatable({
    var = { server_port = "80" }, ctx = {}, log = function() end, ERR = 3, WARN = 5, INFO = 7, time = os.time,
    sleep = function(s) sleeps[#sleeps + 1] = s end,
    timer = { at = function() return true end },
}, { __index = function() return function() end end })

package.loaded["lapis.db"] = {
    query = function() return {} end, select = function() return {} end, update = function() end,
    raw = function(x) return x end, escape_literal = function(x) return "'" .. tostring(x) .. "'" end, NULL = {},
}
local responses, calls = {}, {}
package.loaded["resty.http"] = { new = function()
    return {
        set_timeout = function() end,
        request_uri = function(_, url, opts)
            calls[#calls + 1] = { url = url, auth = opts.headers.Authorization }
            return table.remove(responses, 1)
        end,
    }
end }
package.loaded["middleware.auth"] = { requireAuth = function(f) return f end }
local minted = 0
package.loaded["helper.jwt-helper"] = {
    verifyToken = function() return { valid = true, payload = {} } end,
    reissue = function() minted = minted + 1; return "tok" .. minted end,
}
if not pcall(require, "cjson") then
    package.loaded["cjson"] = { encode = function() return "{}" end, decode = function() return {} end }
end

local internal = require("routes.tax-process")._internal
check("module exposes internal for tests", type(internal) == "function")
local job = { jwt_payload = { userinfo = { uuid = "u-1" } }, port = 8080 }

print("not rate limited")
responses, calls, sleeps = { { status = 200 } }, {}, {}
local res = internal("POST", "/api/v2/tax/classify", "statement_id=x", job)
check("returns the response", res and res.status == 200)
check("one call, no wait", #calls == 1 and #sleeps == 0)
check("calls the job's own port", calls[1].url == "http://127.0.0.1:8080/api/v2/tax/classify", calls[1].url)

print("rate limited twice, then through")
responses, calls, sleeps = {
    { status = 429, headers = { ["Retry-After"] = "12" } },
    { status = 429, headers = { ["retry-after"] = "500" } },
    { status = 200 },
}, {}, {}
res = internal("POST", "/api/v2/tax/classify", "statement_id=x", job)
check("ends with the successful response", res and res.status == 200)
check("three attempts", #calls == 3, #calls)
check("waits Retry-After seconds", sleeps[1] == 12, sleeps[1])
check("caps a long Retry-After at 60s", sleeps[2] == 60, sleeps[2])
check("fresh token on every attempt", calls[1].auth ~= calls[2].auth and calls[2].auth ~= calls[3].auth)

print("429 without Retry-After")
responses, calls, sleeps = { { status = 429, headers = {} }, { status = 200 } }, {}, {}
internal("POST", "/api/v2/tax/extract", "statement_id=x", job)
check("waits 15s by default", sleeps[1] == 15, sleeps[1])

print("other errors are not retried")
responses, calls, sleeps = { { status = 500 } }, {}, {}
res = internal("POST", "/api/v2/tax/classify", "statement_id=x", job)
check("500 returned at once", res.status == 500 and #calls == 1 and #sleeps == 0)
responses, calls, sleeps = {}, {}, {}
res = internal("POST", "/api/v2/tax/classify", "statement_id=x", job)
check("connection failure returned at once", res == nil and #calls == 1)

print("gives up eventually")
responses, calls, sleeps = {}, {}, {}
for _ = 1, 40 do responses[#responses + 1] = { status = 429, headers = { ["Retry-After"] = "1" } } end
res = internal("POST", "/api/v2/tax/classify", "statement_id=x", job)
check("returns the last 429 after 31 attempts", res.status == 429 and #calls == 31, #calls)

print(failures == 0 and "\nall passed" or ("\n" .. failures .. " failed"))
os.exit(failures == 0 and 0 or 1)
