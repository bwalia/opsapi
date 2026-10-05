--[[
    Regression spec: request-supplied ids can't reach another workspace.

    Standalone -- run from the repo root with:
        luajit lapis/spec/tenant-isolation-ids_spec.lua

    Each of these took a bare id (uuid or number) from the request and used it
    without checking it belonged to the caller's workspace or project. Verified
    live (two workspaces, non-admin attacker) before the fix; this guards each
    check from being dropped again.
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
local function count(s, needle)
    local n, i = 0, 1
    while true do
        local j = s:find(needle, i, true)
        if not j then return n end
        n, i = n + 1, j + #needle
    end
end

print("Kanban:")
local sprintq = read("lapis/queries/KanbanSprintQueries.lua")
check("sprint add-tasks only takes tasks on the sprint's own project boards",
    sprintq:find("JOIN kanban_sprints s ON s.project_id = b.project_id", 1, true) ~= nil)
local taskq = read("lapis/queries/KanbanTaskQueries.lua")
check("move only to a column on the task's own board",
    taskq:find("FROM kanban_columns WHERE id = ? AND board_id = ?", 1, true) ~= nil)
check("labels only from the task's own project", taskq:find("Label does not belong to this project", 1, true) ~= nil)
local tasks = read("lapis/routes/kanban-tasks.lua")
check("new task's column must be on its board", tasks:find("Column does not belong to this board", 1, true) ~= nil)
check("parent task must be in the same project", tasks:find("KanbanTaskQueries.inProject(parent_task_id", 1, true) ~= nil)
local sprints = read("lapis/routes/kanban-sprints.lua")
check("sprint board must be in the project", sprints:find("Board does not belong to this project", 1, true) ~= nil)
check("sprint create sets created_by (NOT NULL)", sprints:find("created_by = user.uuid", 1, true) ~= nil)

print("Accounting:")
local acc = read("lapis/queries/AccountingQueries.lua")
local cje = acc:match("function AccountingQueries%.createJournalEntry.-\nend")
check("every journal line's account is checked against the workspace",
    cje and cje:find("accountsInNamespace(ids, params.namespace_id)", 1, true) ~= nil)
check("account check is scoped by namespace and live accounts",
    acc:find("AND namespace_id = ? AND deleted_at IS NULL", 1, true) ~= nil)
check("parent account checked on create + update",
    count(read("lapis/routes/accounting.lua"), "parent_id must be an account in this workspace") == 2)
for _, page in ipairs({ "money-in", "money-out" }) do
    local src = read("opsapi-dashboard/app/dashboard/accounting/" .. page .. "/page.tsx")
    check(page .. " uses the workspace's own bank/VAT accounts (no hard-coded ids)",
        src:find("findControlAccount(accounts, 'bank')", 1, true) ~= nil
        and src:find("account_id: 1,", 1, true) == nil and src:find("account_id: 2,", 1, true) == nil
        and src:find("account_id: 3,", 1, true) == nil)
end

print("Document templates + generated documents:")
local dt = read("lapis/routes/document-templates.lua")
for _, call in ipairs({
    "DocumentTemplateQueries.get(", "DocumentTemplateQueries.update(", "DocumentTemplateQueries.delete(",
    "DocumentTemplateQueries.clone(", "DocumentTemplateQueries.getGeneratedDocument(",
}) do
    local unscoped = 0
    for line in dt:gmatch("[^\n]+") do
        if line:find(call, 1, true) and not line:find("self.namespace.id", 1, true) then unscoped = unscoped + 1 end
    end
    check(call .. " always passes the caller's workspace", unscoped == 0, unscoped .. " unscoped")
end
local dtq = read("lapis/queries/DocumentTemplateQueries.lua")
check("template + document lookups filter by namespace",
    count(dtq, "IS NULL OR dt.namespace_id = ?::bigint") == 1 and count(dtq, "IS NULL OR gd.namespace_id = ?::bigint") == 1)

print("Users + roles:")
local uq = read("lapis/queries/UserQueries.lua")
local search = uq:match("function UserQueries%.search.-\nend")
check("non-admin search is limited to the workspace's members",
    search and search:find("JOIN namespace_members nm", 1, true) ~= nil)
check("invite search matches an exact email only", search and search:find("WHERE LOWER(u.email) = ?", 1, true) ~= nil)
check("route passes the platform-admin flag", read("lapis/routes/users.lua"):find("platform_admin = self.is_platform_admin", 1, true) ~= nil)
local nmq = read("lapis/queries/NamespaceMemberQueries.lua")
check("assignRole + setRoles only accept the member's own workspace roles",
    count(nmq, "not roles_of_members_namespace(member_id") == 2)
check("foreign role is a 400, not a 500",
    count(read("lapis/routes/namespaces.lua"), 'error_response(400, "Role does not belong to this workspace")') == 3)

print("Timesheets:")
local ts = read("lapis/routes/timesheets.lua")
local queue = ts:match('app:get%("/api/v2/timesheets/approval%-queue".-\n    %)%)')
check("approval queue only for approvers", queue and queue:find("if not can_view_others(self) then", 1, true) ~= nil)

print(failures == 0 and "\nAll checks passed." or ("\n" .. failures .. " check(s) FAILED."))
os.exit(failures == 0 and 0 or 1)
