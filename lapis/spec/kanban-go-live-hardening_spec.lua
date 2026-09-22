--[[
    Regression spec: kanban go-live hardening.

    Standalone -- no busted/luarocks needed. Run from the repo root with:
        luajit lapis/spec/kanban-go-live-hardening_spec.lua

    Guards a batch of pre-launch fixes so they can't silently regress:
      1. Pagination is clamped (Global.pageParam/perPageParam) at every route
         param-build, so ?perPage=0 (Inf -> cjson 500) and ?page=-1 (negative
         Postgres LIMIT/OFFSET -> 500) can't 500 a list endpoint.
      2. Assigning a task grants project membership, so an assignee's MCP agent
         can actually act on the task (not just see it in list_my_tasks).
      3. addMember rejects a non-namespace user (no dead-end members).
      4. Numeric body/path params are tonumber-coerced before hitting integer
         columns (move column_id, add-label label_id).
      5. The time-entry UPDATE route pcall-wraps like its create sibling.
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

print("pagination clamp helpers:")
local g = read("lapis/helper/global.lua")
check("Global.pageParam exists", g:find("function Global%.pageParam") ~= nil)
check("Global.perPageParam exists", g:find("function Global%.perPageParam") ~= nil)
check("perPageParam caps an upper bound (max)",
    g:find("if n > max then return max end", 1, true) ~= nil)
check("pageParam floors to >= 1",
    g:find("if n < 1 then return 1 end", 1, true) ~= nil)

print("\nno route still uses the raw unclamped idiom:")
local route_files = {
    "kanban-projects", "kanban-tasks", "kanban-epics", "kanban-sprints",
    "kanban-analytics", "kanban-notifications", "kanban-time-tracking",
}
for _, name in ipairs(route_files) do
    local src = read("lapis/routes/" .. name .. ".lua")
    local raw = src:find("tonumber%(self%.params%.perPage%) or")
        or src:find("tonumber%(self%.params%.per_page%) or")
        or src:find("tonumber%(self%.params%.page%) or 1")
    check(name .. ".lua: all page/perPage params clamped via Global", raw == nil)
end

print("\nassignment grants project membership:")
local tq = read("lapis/queries/KanbanTaskQueries.lua")
local assign = tq:match("function KanbanTaskQueries%.assignUser.-\nend")
check("assignUser inserts into kanban_project_members",
    assign and assign:find("INSERT INTO kanban_project_members", 1, true) ~= nil)
check("membership grant is best-effort (pcall, never fails the assignment)",
    assign and assign:find("pcall(function()", 1, true) ~= nil)

print("\naddMember requires namespace membership:")
local pq = read("lapis/queries/KanbanProjectQueries.lua")
local addm = pq:match("function KanbanProjectQueries%.addMember.-\nend")
check("addMember checks namespace_members before adding",
    addm and addm:find("namespace_members", 1, true) ~= nil
        and addm:find("must be a member of this workspace", 1, true) ~= nil)

print("\nnumeric params are coerced before integer columns:")
local rt = read("lapis/routes/kanban-tasks.lua")
check("move coerces column_id via tonumber",
    rt:find("local column_id = tonumber(data.column_id)", 1, true) ~= nil)
check("add-label coerces label_id via tonumber",
    rt:find("local label_id = tonumber(data.label_id)", 1, true) ~= nil)

print("\ntime-entry update is pcall-guarded like create:")
local tt = read("lapis/routes/kanban-time-tracking.lua")
check("update route pcall-wraps KanbanTimeTrackingQueries.update",
    tt:find("pcall(\n            KanbanTimeTrackingQueries.update", 1, true) ~= nil
        or tt:find("pcall(%s*KanbanTimeTrackingQueries%.update") ~= nil)

print("")
if failures > 0 then
    print(failures .. " failure(s)")
    os.exit(1)
end
print("all checks passed")
