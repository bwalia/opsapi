--[[
    Regression spec: Employees is a CORE module (not field-service-bound).

    Standalone -- run from the repo root with:
        luajit lapis/spec/employees-core-module_spec.lua

    Employees was welded to field service (route gated on field_service, RBAC
    module in the field_service group, API under /api/v2/field-service, menu at
    /dashboard/field-service/employees). It is a generic staff directory, so it
    was promoted to a core module available to any namespace. This guards the
    decoupling from silently regressing back under field service.
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

print("RBAC module group:")
local pc = read("lapis/helper/project-config.lua")
local core_group = pc:match("core = {.-\n    }")
local fs_group = pc:match("field_service = {.-\n    }", pc:find("PROJECT_MODULES"))
check("employees module is in the core group",
    core_group and core_group:find('machine_name = "employees"', 1, true) ~= nil)
check("employees module is NOT in the field_service group",
    fs_group and fs_group:find('machine_name = "employees"', 1, true) == nil)

print("\nroute loading:")
local app = read("lapis/app.lua")
check("routes.employees is loaded (core, always on)",
    app:find('safe_load_routes("routes.employees")', 1, true) ~= nil)
check("the old field-service-employees route is no longer loaded",
    app:find("routes.field-service-employees", 1, true) == nil)

print("\nroute file: neutral path + backward-compat alias:")
local rt = read("lapis/routes/employees.lua")
check("mounts the canonical /api/v2/employees path",
    rt:find('"/api/v2/employees"', 1, true) ~= nil)
check("mounts the legacy /api/v2/field-service/employees alias",
    rt:find('"/api/v2/field-service/employees"', 1, true) ~= nil)
check("exposes the core member picker /api/v2/employees/candidates",
    rt:find('"/api/v2/employees/candidates"', 1, true) ~= nil)

print("\nmenu migration (core-gated, neutral URL):")
local mig = read("lapis/migrations/employees.lua")
check("re-paths the Employees menu item to /dashboard/employees",
    mig:find("/dashboard/employees", 1, true) ~= nil)
local reg = read("lapis/migrations.lua")
check("employees migration is registered gated on CORE",
    reg:find("employees_core_migrations", 1, true) ~= nil
        and reg:find("ProjectConfig.FEATURES.CORE, employees_core_migrations", 1, true) ~= nil)

print("")
if failures > 0 then
    print(failures .. " failure(s)")
    os.exit(1)
end
print("all checks passed")
