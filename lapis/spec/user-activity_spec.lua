--[[
    Regression spec: user activity tracking — route normalisation and the
    client IP behind proxies. Pure functions, no database.

    Standalone — run from the repo root with:
        luajit lapis/spec/user-activity_spec.lua
]]

package.path = "lapis/?.lua;lapis/?/init.lua;" .. package.path

local failures = 0
local function check(name, ok, detail)
    if ok then
        print("  ok   - " .. name)
    else
        failures = failures + 1
        print("  FAIL - " .. name .. (detail and ("  (" .. tostring(detail) .. ")") or ""))
    end
end

local UserActivity = require("lib.user-activity")
local ClientIP = require("helper.client-ip")

print("normalize: route / entity / resource")
local function norm(uri) return { UserActivity.normalize(uri) } end
local r = norm("/api/v2/customers")
check("collection", r[1] == "/api/v2/customers" and r[2] == nil and r[3] == "customers", table.concat(r, " "))
r = norm("/api/v2/customers/5f0e2a1c-1111-4222-8333-944455556666")
check("uuid becomes :id and is the entity", r[1] == "/api/v2/customers/:id"
    and r[2] == "5f0e2a1c-1111-4222-8333-944455556666" and r[3] == "customers", table.concat(r, " "))
r = norm("/api/v2/crm/accounts/42/contacts")
check("nested resource, numeric id", r[1] == "/api/v2/crm/accounts/:id/contacts" and r[2] == "42"
    and r[3] == "crm.accounts.contacts", table.concat(r, " "))
r = norm("/api/v2/care-plans/due-for-review")
check("word segments kept", r[1] == "/api/v2/care-plans/due-for-review" and r[3] == "care-plans.due-for-review")
r = norm("/api/v2/invoices/INV-2026-000123/pdf")
check("numbered slugs/tokens are ids", r[1] == "/api/v2/invoices/:id/pdf" and r[2] == "INV-2026-000123")
r = norm("/api/v2/auth/2fa/verify")
check("short words with digits are not ids", r[1] == "/api/v2/auth/2fa/verify", r[1])
r = norm("/" .. string.rep("a/", 40))
check("depth capped", select(2, r[1]:gsub("/", "")) <= 12)

print("client ip")
check("direct public peer: headers ignored (no spoofing)",
    ClientIP.get("198.51.100.20", "1.2.3.4") == "198.51.100.20")
check("behind internal proxy: right-most non-proxy hop",
    ClientIP.get("10.42.0.7", "6.6.6.6, 203.0.113.9") == "203.0.113.9")
check("spoofed left-most entry ignored",
    ClientIP.get("10.42.0.7", "1.1.1.1, 203.0.113.9, 10.42.0.3") == "203.0.113.9")
check("ports stripped", ClientIP.get("10.0.0.1", "203.0.113.9:51234") == "203.0.113.9")
check("all-internal chain → first hop", ClientIP.get("10.0.0.1", "10.0.0.9, 10.0.0.8") == "10.0.0.9")
check("X-Real-IP from a trusted proxy", ClientIP.get("192.168.1.1", nil, "203.0.113.50") == "203.0.113.50")
check("private ranges trusted", ClientIP.isTrusted("172.16.0.1") and ClientIP.isTrusted("127.0.0.1")
    and ClientIP.isTrusted("100.64.1.1") and not ClientIP.isTrusted("172.32.0.1")
    and not ClientIP.isTrusted("8.8.8.8"))
check("IPv6 loopback / ULA trusted", ClientIP.isTrusted("::1") and ClientIP.isTrusted("fd12::1")
    and not ClientIP.isTrusted("2001:db8::1"))

print("workspace activity view: wiring")
local function read(path)
    local f = assert(io.open(path))
    local text = f:read("*a")
    f:close()
    return text
end
local routes = read("lapis/routes/namespace-activity.lua")
local _, guarded = routes:gsub('Http%.guard%("activity", "read"', "")
local _, mounted = routes:gsub("app:get%(", "")
check("every activity endpoint requires activity.read", mounted == 4 and guarded == 4, mounted .. "/" .. guarded)
check("route file loaded for every deployment",
    read("lapis/app.lua"):find('safe_load_routes%("routes%.namespace%-activity"%)') ~= nil)
check("activity is a core RBAC module (menu gate)",
    read("lapis/helper/project-config.lua"):match("core = {.-\n    }"):find('machine_name = "activity"') ~= nil)
local queries = read("lapis/queries/ActivityQueries.lua")
local _, scoped = queries:gsub("namespace_id = %?", "")
check("activity queries are namespace-scoped", scoped >= 6, scoped)
check("activity rows and daily counters written in one statement",
    read("lapis/lib/user-activity.lua"):find('"WITH ins AS %(" %.%. rows %.%. ROLLUP') ~= nil)

local lib = read("lapis/lib/user-activity.lua")
check("errors are logged without the SQL (it holds emails / IPs)",
    not lib:find("ngx%.log%([^\n]*tostring%(err%)") and lib:find("db_error%(err%)") ~= nil)
check("recording pauses when the tables are not migrated yet",
    lib:find("function UserActivity%.capture%(%)\n    if not ENABLED or ngx%.now%(%) < paused_until") ~= nil)

print(failures == 0 and "\nall passed" or ("\n" .. failures .. " failure(s)"))
os.exit(failures == 0 and 0 or 1)
