--[[
    Regression spec: the care-management tables exist after migrating.

    Standalone -- no busted/luarocks needed. Run from the repo root with:
        luajit lapis/spec/hospital-care-tables-backfill_spec.lua

    Lapis runs migration keys in string order, so 442-453 (care_plans, medications,
    daily_logs, ...) run BEFORE 47_create_hospitals_table. Their require_hospitals
    guard skipped them, lapis recorded them as applied anyway, and they never ran
    again -- every Care Home route then queried missing tables (int had none of the
    12). zzhc_hospital_care_tables_backfill re-creates whatever is missing; this
    guards its ordering and its index -> table mapping.
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

local registry = read("lapis/migrations.lua")
local module = read("lapis/migrations/hospital-care-management.lua")
local KEY = "zzhc_hospital_care_tables_backfill"

print("backfill is registered behind the hospital feature:")
check("key present", registry:find("['" .. KEY .. "'] = conditional(ProjectConfig.FEATURES.HOSPITAL", 1, true))

print("backfill runs after the tables it depends on:")
check("sorts after 47_create_hospitals_table", KEY > "47_create_hospitals_table")
check("sorts after 48_create_patients_table", KEY > "48_create_patients_table")
for n = 442, 453 do
    local key = registry:match("%['(" .. n .. "_[%w_]+)'%] = conditional_array%(ProjectConfig%.FEATURES%.HOSPITAL, "
        .. "hospital_care_mgmt_migrations")
    check(n .. " registered", key ~= nil)
    if key then check("sorts after " .. key, KEY > key) end
end

print("backfill table list matches the module's migration order:")
local module_tables = {}
for name in module:gmatch('schema%.create_table%("([%w_]+)"') do
    module_tables[#module_tables + 1] = name
end
local body = registry:match("%['" .. KEY .. "'%].-local tables = (%b{})")
check("table list found", body ~= nil)
local listed = {}
for name in (body or ""):gmatch('"([%w_]+)"') do
    listed[#listed + 1] = name
end
check("12 tables listed", #listed == 12, #listed)
check("module defines 12 tables", #module_tables == 12, #module_tables)
for i, name in ipairs(module_tables) do
    check("[" .. i .. "] " .. name, listed[i] == name, listed[i])
end

print("backfill only creates what is missing:")
check("checks to_regclass before creating", registry:find("SELECT to_regclass(?) IS NOT NULL AS present", 1, true))

print(failures == 0 and "\nPASS" or ("\nFAILED: " .. failures))
os.exit(failures == 0 and 0 or 1)
