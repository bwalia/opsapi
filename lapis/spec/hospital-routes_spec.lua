--[[
    Regression spec: the Health Care menu's root APIs exist and stay tenant-scoped.

    Standalone -- no busted/luarocks needed. Run from the repo root with:
        luajit lapis/spec/hospital-routes_spec.lua

    routes/hospitals.lua + routes/patients.lua were deleted in 4fca0845 while the
    dashboard (Hospitals, Patients, Care Home pages) still called /api/v2/hospitals
    and /api/v2/patients -- every Health Care page showed "Failed to load". This
    guards that they are registered, gated, and filter by the caller's namespace.
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

local app = read("lapis/app.lua")
local migrations = read("lapis/migrations.lua")

print("routes are loaded behind the hospital feature, after the tenant gate:")
local scope_at = app:find('load_if("hospital", "routes.hospital-scope")', 1, true)
for _, mod in ipairs({ "hospitals", "patients" }) do
    local at = app:find('load_if("hospital", "routes.' .. mod .. '")', 1, true)
    check(mod .. " registered", at ~= nil)
    check(mod .. " after hospital-scope", at and scope_at and at > scope_at)
end

for _, spec in ipairs({
    { file = "hospitals", base = "/api/v2/hospitals", scope = "namespace_id = ?" },
    { file = "patients", base = "/api/v2/patients", scope = "h.namespace_id = ?" },
}) do
    local src = read("lapis/routes/" .. spec.file .. ".lua")
    print(spec.file .. ".lua:")
    for _, route in ipairs({
        'app:get("' .. spec.base .. '"', 'app:post("' .. spec.base .. '"',
        'app:get("' .. spec.base .. '/:uuid"', 'app:put("' .. spec.base .. '/:uuid"',
        'app:delete("' .. spec.base .. '/:uuid"',
    }) do
        check(route, src:find(route, 1, true) ~= nil)
    end
    check("list filtered by caller namespace", src:find(spec.scope, 1, true) ~= nil)
    check("permission-gated", src:find('requirePermission(PERMISSION_MODULE', 1, true) ~= nil)
    check("no unauthenticated handlers", select(2, src:gsub("app:%a+%(", "")) == select(2, src:gsub("guarded%(", "")) - 1)
end

print("hospitals contact columns are optional (form only requires name + license):")
check("zzhd migration registered",
    migrations:find("['zzhd_hospitals_optional_contact_fields'] = conditional(ProjectConfig.FEATURES.HOSPITAL", 1, true))
check("zzhd sorts after hospitals table creation", "zzhd_hospitals_optional_contact_fields" > "47_create_hospitals_table")

if failures > 0 then
    print(failures .. " failure(s)")
    os.exit(1)
end
print("all passed")
