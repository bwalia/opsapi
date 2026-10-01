--[[
    Regression spec: the legacy /api/v2/projects CRUD is platform-admin only.

    The `projects` table has no namespace_id, so these records are global; with
    plain requireAuth any signed-in user of any workspace could read and change
    every row.

    Standalone — run from the repo root with:
        luajit lapis/spec/legacy-projects-admin-only_spec.lua
]]

local failures = 0
local function check(name, ok)
    print((ok and "  ok   - " or "  FAIL - ") .. name)
    if not ok then failures = failures + 1 end
end

local f = assert(io.open("lapis/routes/projects.lua"))
local src = f:read("*a")
f:close()

local _, routes = src:gsub("app:%a+%(\"/api/v2/projects", "")
local _, guarded = src:gsub('AuthMiddleware%.requireRole%("administrative", function%(self%)', "")
check("five routes registered", routes == 5)
check("every route requires the platform admin role", guarded == 5)
check("no route left on plain requireAuth", not src:find("requireAuth%("))

print(failures == 0 and "\nall passed" or ("\n" .. failures .. " failure(s)"))
os.exit(failures == 0 and 0 or 1)
