--[[
    Regression spec: a task's epic_id stays inside the task's own tenant.

    Standalone -- no busted/luarocks needed. Run from the repo root with:
        luajit lapis/spec/kanban-epic-tenant-gate_spec.lua

    Epics (#638) added epic_id as the first FK writable through the GENERIC task
    path (POST /boards/:uuid/tasks, PUT /tasks/:uuid) -- sprint_id never was.
    That path sets epic_id straight from the body and cannot reach
    assignTasks' scoping, so before this fix an editor in tenant A could pin
    their task to tenant B's epic (ids are sequential -> guessable): A's board
    would then show B's epic name/colour, and A's task would surface in B's
    epic task list + rollups.

    The fix is a tenant gate -- KanbanEpicQueries.belongsToProject(epic_id,
    project_id) -- enforced on both write paths, plus namespace scoping on the
    reads that render or aggregate epic-linked tasks. This guards against any
    of those gates being dropped.
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

print("tenant gate predicate:")
local eq = read("lapis/queries/KanbanEpicQueries.lua")
local belongs = eq:match("function KanbanEpicQueries%.belongsToProject.-\nend")
check("belongsToProject() exists", belongs ~= nil)
check("belongsToProject() filters by project_id and skips soft-deleted epics",
    belongs and belongs:find("project_id = ?", 1, true) ~= nil
        and belongs:find("deleted_at IS NULL", 1, true) ~= nil)
check("belongsToProject() treats nil epic (detach) as allowed",
    belongs and belongs:find("epic_id == nil", 1, true) ~= nil)

print("\nwrite paths are gated:")
local rt = read("lapis/routes/kanban-tasks.lua")
-- Both create and PUT must run the gate before persisting epic_id: one call per
-- write path.
local gate_calls = select(2, rt:gsub("KanbanEpicQueries%.belongsToProject%(", ""))
check("both task write paths call belongsToProject (create + update)",
    gate_calls >= 2, gate_calls .. " call(s)")
check("gate is scoped to the task's own project (board.project_id)",
    rt:find("belongsToProject(epic_id, board.project_id)", 1, true) ~= nil)

print("\nreads are namespace-scoped:")
-- getTasks: takes the resolved epic and matches p.namespace_id, so a foreign
-- task pinned to this epic id never appears in its list/count.
local getTasks = eq:match("function KanbanEpicQueries%.getTasks.-\nend")
check("getTasks() takes the epic row, not a bare id",
    getTasks and getTasks:find("getTasks(epic, params)", 1, true) ~= nil)
check("getTasks() scopes tasks to the epic's namespace",
    getTasks and getTasks:find("p.namespace_id = ?", 1, true) ~= nil)

-- Rollup counts only same-tenant tasks.
check("rollup aggregate matches task tenant to epic tenant",
    eq:find("p.namespace_id = ep.namespace_id", 1, true) ~= nil)

-- Task reads that already join the project scope the epic join too.
local tq = read("lapis/queries/KanbanTaskQueries.lua")
local scoped_epic_joins = select(2,
    tq:gsub("kanban_epics e ON e%.id = t%.epic_id AND e%.deleted_at IS NULL AND e%.namespace_id = p%.namespace_id", ""))
check("show() + getByAssignee() epic joins are namespace-scoped",
    scoped_epic_joins >= 2, scoped_epic_joins .. " scoped join(s)")

print("")
if failures > 0 then
    print(failures .. " failure(s)")
    os.exit(1)
end
print("all checks passed")
