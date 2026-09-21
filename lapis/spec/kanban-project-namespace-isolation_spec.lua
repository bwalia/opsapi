--[[
    Regression spec: Kanban project reads are namespace-isolated.

    Standalone — no busted/luarocks needed. Run from the repo root with:
        luajit lapis/spec/kanban-project-namespace-isolation_spec.lua

    Guards the multi-tenant boundary on the Kanban project routes. Before this
    fix, GET /api/v2/kanban/projects/:uuid returned a non-private project from
    ANOTHER namespace to any caller holding projects.read (an IDOR): the query
    fetched by uuid only, and the route blocked cross-tenant access solely on
    `visibility == private`. Now KanbanProjectQueries.show takes a namespace_id
    and every kanban-projects.lua route passes self.namespace.id, so a project
    UUID from another namespace resolves to nil → 404.
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

print("query:")
local q = read("lapis/queries/KanbanProjectQueries.lua")
local show = q:match("function KanbanProjectQueries%.show.-\nend")
check("show() accepts a namespace_id parameter",
    show and show:find("namespace_id", 1, true) ~= nil)
check("show() filters by p.namespace_id when given",
    show and show:find("AND p.namespace_id = ?", 1, true) ~= nil)

print("\nroutes:")
local r = read("lapis/routes/kanban-projects.lua")
-- Every show() call in the projects routes must be namespace-scoped. Count the
-- calls and the ones that pass self.namespace.id; they must match.
local total = select(2, r:gsub("KanbanProjectQueries%.show%(", ""))
local scoped = select(2, r:gsub("KanbanProjectQueries%.show%([^)]-self%.namespace%.id", ""))
check("all projects.lua show() calls pass self.namespace.id",
    total > 0 and scoped == total,
    scoped .. "/" .. total .. " scoped")

print("")
if failures > 0 then
    print(failures .. " failure(s)")
    os.exit(1)
end
print("all checks passed")
