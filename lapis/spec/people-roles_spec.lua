--[[
    Regression spec: a new Developer can actually work, and task links open.

    Standalone -- run from the repo root with:
        luajit lapis/spec/people-roles_spec.lua

    - The "developer" role used to be seeded with no access, so a developer signed in to an empty dashboard.
    - Task/project notifications linked to /projects/... (no /dashboard), which 404s in the dashboard.
    - The F-Gas column only exists with field service, so the core employees code must not always write it.
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
local function read(path)
    local h = assert(io.open(path))
    local s = h:read("*a")
    h:close()
    return s
end

print("developer role:")
local nrq = read("lapis/queries/NamespaceRoleQueries.lua")
local preset = nrq:match("NamespaceRoleQueries.DEVELOPER_PERMISSIONS = {(.-)\n}")
for _, need in ipairs({ 'projects = { "read"', 'timesheets = { "read"', "chat = {", "ai_runs = {" }) do
    check("preset grants " .. need:match("^[%w_]+"), preset and preset:find(need, 1, true) ~= nil)
end
local dev = nrq:match('role_name = "developer",(.-)}%)')
check("new developer roles get the preset", dev and dev:find("DEVELOPER_PERMISSIONS", 1, true) ~= nil)
check("new developer roles land on My tasks", dev and dev:find("DEVELOPER_LANDING", 1, true) ~= nil)
check("backfill seeds every developer role and only adds",
    nrq:find("role_name = 'developer'", 1, true) ~= nil and nrq:find("table.insert(have, a)", 1, true) ~= nil)

print("\nmigrations:")
local mig = read("lapis/migrations.lua")
check("existing developer roles are backfilled", mig:find("backfillDeveloperPreset()", 1, true) ~= nil)
check("stored notification links are repaired", mig:find("'/dashboard' || action_url", 1, true) ~= nil)

print("\nnotification links:")
local kn = read("lapis/queries/KanbanNotificationQueries.lua")
check("no link without /dashboard", kn:find('"/projects/', 1, true) == nil)
check("links go to /dashboard/projects/", kn:find('"/dashboard/projects/', 1, true) ~= nil)

print("\nemployees (any industry):")
local eq = read("lapis/queries/EmployeeQueries.lua")
local text_fields = eq:match("local TEXT_FIELDS = {(.-)}")
check("F-Gas is not a core field", text_fields and text_fields:find("fgas", 1, true) == nil)
check("F-Gas is added only with field service",
    eq:find('FEATURES.FIELD_SERVICE) then\n    table.insert(TEXT_FIELDS, "fgas_certificate_no")', 1, true) ~= nil)
check("a failed profile never undoes the new login", eq:find("pcall(EmployeeQueries.createEmployee", 1, true) ~= nil)

if failures > 0 then
    print(("\n%d check(s) failed"):format(failures))
    os.exit(1)
end
print("\nall checks passed")
