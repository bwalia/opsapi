--[[
    Regression spec: dynamic per-role landing + namespace-aware kanban RBAC.

    Standalone — no busted/luarocks needed. Run from the repo root with:
        luajit lapis/spec/namespace-rbac-landing_spec.lua

    Guards three connected features so they can't silently break:
      1. Per-namespace-role landing_path (data-driven post-login redirect).
      2. Kanban authz bridged to namespace authority (owner / platform admin /
         projects.manage manages any project in their tenant).
      3. Task assignment gated to namespace members (tenant boundary).
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
local function has(s, needle) return s:find(needle, 1, true) ~= nil end

print("landing path — migration + queries:")
local mig = read("lapis/migrations/namespace-system.lua")
check("adds namespace_roles.landing_path", has(mig, '"landing_path"'))
check("backfills existing developer role", has(mig, "'developer'"))
check("registered in migrations.lua", has(read("lapis/migrations.lua"), "762_add_landing_path"))
local nrq = read("lapis/queries/NamespaceRoleQueries.lua")
check("create() persists landing_path", has(nrq, "landing_path = data.landing_path"))
check("seeds a developer role by default", has(nrq, 'role_name = "developer"'))
check("field-service roles seed a landing_path", has(nrq, '"/dashboard/field-service"'))

print("\nlanding path — JWT + route:")
local jwt = read("lapis/helper/jwt-helper.lua")
check("token carries namespace.landing_path", has(jwt, "userinfo.namespace.landing_path"))
check("namespace token looks up the role's landing_path",
    has(jwt, "SELECT landing_path FROM namespace_roles"))
check("role create route accepts landing_path",
    has(read("lapis/routes/namespaces.lua"), "landing_path = params.landing_path"))

print("\nnamespace-aware kanban authz:")
local kpq = read("lapis/queries/KanbanProjectQueries.lua")
check("has the nsPrivileged bridge", has(kpq, "function nsPrivileged"))
check("bridge checks namespace owner", has(kpq, "nm.is_owner = true"))
check("bridge checks platform admin", has(kpq, "isPlatformAdmin"))
check("bridge checks projects.manage", has(kpq, "perms.projects"))
-- All three gates must OR in the bridge.
local bridged = select(2, kpq:gsub("return nsPrivileged%(project_id, user_uuid%)", ""))
check("isMember/isEditor/isAdmin all OR in the bridge", bridged >= 3, bridged .. " sites")

print("\nassignment tenant gate:")
local ktq = read("lapis/queries/KanbanTaskQueries.lua")
check("assignUser rejects non-namespace-members",
    has(ktq, "User is not a member of this namespace"))

print("\nfrontend wiring:")
check("dashboard redirect is data-driven (landingPath)",
    has(read("opsapi-dashboard/app/dashboard/page.tsx"), "landingPath"))
check("PermissionsContext exposes landingPath",
    has(read("opsapi-dashboard/contexts/PermissionsContext.tsx"), "landingPath"))
local proj = read("opsapi-dashboard/app/dashboard/projects/[uuid]/page.tsx")
check("canEdit bridges namespace authority",
    has(proj, "isNamespaceOwner") and has(proj, "canManage('projects')"))
check("assignee picker uses namespace members", has(proj, "assignableMembers"))
check("board sensors are constant (crash fix)",
    has(read("opsapi-dashboard/components/kanban/KanbanBoard.tsx"), "sensors={sensors}"))

print("")
if failures > 0 then
    print(failures .. " failure(s)")
    os.exit(1)
end
print("all checks passed")
