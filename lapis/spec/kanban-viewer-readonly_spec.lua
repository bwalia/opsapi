--[[
    Regression spec: Kanban read-only members cannot mutate the board.

    Standalone — run from the repo root with:
        luajit lapis/spec/kanban-viewer-readonly_spec.lua

    Before this fix, every task/comment/checklist/label/assignee route and the
    sprint task-assignment routes gated only on isMember(), which is true for the
    `viewer` role — so a read-only member could create/move/delete tasks. Now
    those mutations additionally require isEditor() (owner/admin/member, NOT
    viewer/guest). Boards, columns, labels and sprint CRUD were already
    isAdmin-gated. This guards against a mutation route regressing back to a
    bare isMember() check.
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

print("editor predicate:")
local q = read("lapis/queries/KanbanProjectQueries.lua")
local isEditor = q:match("function KanbanProjectQueries%.isEditor.-\nend")
check("isEditor() exists", isEditor ~= nil)
check("isEditor() allow-lists owner/admin/member (fail-safe, not a viewer deny-list)",
    isEditor and isEditor:find("IN %('owner', 'admin', 'member'%)") ~= nil)

print("\ntask mutations gated:")
local t = read("lapis/routes/kanban-tasks.lua")
-- create/update/delete/move task, assignee add/remove, label add/remove,
-- comment add + the create-task board check = 11 inline isEditor guards.
local task_gates = select(2, t:gsub("KanbanProjectQueries%.isEditor%(", ""))
check("task routes carry the editor gate (>= 11 sites)",
    task_gates >= 11, task_gates .. " isEditor sites")
-- checklist/item mutations route through the editor-checking helpers.
local chk_edit = select(2, t:gsub("authorize_checklist_edit%(", ""))
local item_edit = select(2, t:gsub("authorize_checklist_item_edit%(", ""))
check("checklist mutations use authorize_checklist_edit (def + 2 routes)", chk_edit >= 3, chk_edit)
check("checklist-item mutations use authorize_checklist_item_edit (def + 2 routes)", item_edit >= 3, item_edit)

print("\nsprint task-assignment gated:")
local s = read("lapis/routes/kanban-sprints.lua")
check("sprint add/remove-tasks require an editor (2 sites)",
    select(2, s:gsub("KanbanProjectQueries%.isEditor%(", "")) == 2)

print("")
if failures > 0 then
    print(failures .. " failure(s)")
    os.exit(1)
end
print("all checks passed")
