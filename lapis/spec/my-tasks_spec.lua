--[[
    Spec: My tasks — the filter parser behind GET /api/v2/kanban/my-tasks and the
    assistant's list_my_tasks, the SQL it builds (bound values only, tenant +
    assignee scoped, priority/due order) and the tool's row shape.

    Standalone (no busted). Run from the repo root:
        luajit lapis/spec/my-tasks_spec.lua
    The database paths run for real in spec/my-tasks-e2e/run.sh.
]]

package.path = "lapis/?.lua;lapis/?/init.lua;./?.lua;" .. package.path
ngx = ngx or { log = function() end, ERR = 3, WARN = 4, INFO = 7 } -- luacheck: ignore 111

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
    local h = io.open(path) or assert(io.open((path:gsub("^lapis/", ""))))
    local s = h:read("*a")
    h:close()
    return s
end
local function same(a, b)
    if #a ~= #b then return false end
    for i = 1, #a do if a[i] ~= b[i] then return false end end
    return true
end

-- Stubs: a recording lapis.db, empty models, no HTTP.
local calls, rows = {}, {}
local LIST = {}
package.loaded["lapis.db"] = {
    NULL = {},
    raw = function(s) return s end,
    list = function(t) return setmetatable({ items = t }, LIST) end,
    query = function(sql, ...)
        calls[#calls + 1] = { sql = sql, values = { ... } }
        if sql:find("COUNT%(%*%)") then return { { total = #rows } } end
        local out = {}
        for i, r in ipairs(rows) do
            local copy = {}
            for k, v in pairs(r) do copy[k] = v end
            out[i] = copy
        end
        return out
    end,
}
for _, m in ipairs({ "KanbanTaskModel", "KanbanTaskAssigneeModel", "KanbanTaskCommentModel",
    "KanbanTaskAttachmentModel", "KanbanTaskChecklistModel", "KanbanChecklistItemModel", "KanbanTaskActivityModel",
    "KanbanTaskLabelLinkModel", "ChatChannelModel", "ChatChannelMemberModel" }) do
    package.loaded["models." .. m] = {}
end
package.loaded["helper.global"] = { generateUUID = function() return "uuid" end }
for _, m in ipairs({ "queries.CustomerQueries", "queries.EmployeeQueries", "queries.TimesheetQueries",
    "lib.agent.scopes" }) do
    package.loaded[m] = {}
end
if not pcall(require, "resty.http") then package.loaded["resty.http"] = {} end

local Q = require("queries.KanbanTaskQueries")
local parse = Q.parseMyTaskFilters
local UTC_TODAY = os.date("!%Y-%m-%d")

print("Filter parser:")
local f = parse({})
check("no filters: all open tasks, today = UTC date", f and f.due == nil and f.date == UTC_TODAY
    and f.priorities == nil and f.statuses == nil and f.search == nil and f.project_uuid == nil)
for _, due in ipairs({ "today", "overdue", "today_and_overdue", "week", "upcoming", "none" }) do
    check("due=" .. due .. " accepted", (parse({ due = due }) or {}).due == due)
end
for _, bad in ipairs({ "tomorrow", "TODAY", "today,overdue", " today" }) do
    local ok, err = parse({ due = bad })
    check("due=" .. bad .. " refused", ok == nil and err:find("due must be one of", 1, true))
end
check("a repeated due key (table) is refused", parse({ due = { "today" } }) == nil)
check("empty due = no due filter", parse({ due = "" }).due == nil)

for _, d in ipairs({ "2026-10-12", "2024-02-29", "2000-02-29", "1970-01-01", "2026-12-31" }) do
    check("date " .. d .. " accepted", (parse({ date = d }) or {}).date == d)
end
for _, d in ipairs({ "2023-02-29", "1900-02-29", "2026-13-01", "2026-04-31", "2026-00-10", "2026-01-00",
    "26-01-01", "2026-1-1", "2026-01-01x", " 2026-01-01", "1969-12-31", "0000-01-01", "today" }) do
    local ok, err = parse({ date = d })
    check("date " .. d .. " refused", ok == nil and err:find("YYYY-MM-DD", 1, true))
end
check("date as a table is refused", parse({ date = { "2026-10-12" } }) == nil)

check("priority csv normalised (case, spaces, duplicates)",
    same(parse({ priority = "High, critical ,high" }).priorities, { "high", "critical" }))
check("priority list from a model/repeated key", same(parse({ priority = { "low", "none" } }).priorities,
    { "low", "none" }))
check("empty priority csv = no filter", parse({ priority = " , ," }).priorities == nil)
for _, bad in ipairs({ "urgent", "high,urgent", "1" }) do
    local ok, err = parse({ priority = bad })
    check("priority=" .. bad .. " refused", ok == nil and err:find("priority must be", 1, true))
end
check("priority list with a non-string is refused", parse({ priority = { "low", {} } }) == nil)

check("status csv accepted", same(parse({ status = "open,review,blocked,in_progress" }).statuses,
    { "open", "review", "blocked", "in_progress" }))
for _, bad in ipairs({ "completed", "cancelled", "open,done" }) do
    local ok, err = parse({ status = bad })
    check("status=" .. bad .. " refused (closed work never listed)", ok == nil and err:find("status must be", 1, true))
end

check("search trimmed", parse({ search = "  login bug  " }).search == "login bug")
check("search capped at 200 chars", #parse({ search = ("x"):rep(500) }).search == 200)
check("blank search = no filter", parse({ search = "   " }).search == nil)
check("search as a table is refused", parse({ search = { "a" } }) == nil)
check("project_uuid kept", parse({ project_uuid = "abc-123" }).project_uuid == "abc-123")

print("SQL:")
local function last_select()
    for i = #calls, 1, -1 do
        if not calls[i].sql:find("COUNT%(%*%)") then return calls[i] end
    end
end
local function last_count()
    for i = #calls, 1, -1 do
        if calls[i].sql:find("COUNT%(%*%)") then return calls[i] end
    end
end
local function run(raw, page, per_page)
    calls = {}
    return Q.getByAssignee("user-1", 7, { page = page or 1, perPage = per_page or 20, filters = assert(parse(raw)) })
end

run({ date = "2030-06-15" })
local s, c = last_select(), last_count()
check("scoped to the namespace and the assignee (bound)", s.sql:find("p.namespace_id = ?", 1, true)
    and s.sql:find("ta.user_uuid = ? AND ta.deleted_at IS NULL", 1, true)
    and s.values[2] == 7 and s.values[3] == "user-1")
check("closed and archived work excluded", s.sql:find("t.status NOT IN ('completed', 'cancelled')", 1, true)
    and s.sql:find("t.archived_at IS NULL", 1, true))
check("overdue flag relative to the given date", s.sql:find("t.due_date < ?::date) as overdue", 1, true)
    and s.values[1] == "2030-06-15")
check("order: priority, due date (nulls last), created_at", s.sql:find(
    "WHEN 'critical' THEN 1.-WHEN 'high' THEN 2.-WHEN 'medium' THEN 3.-WHEN 'low' THEN 4.-ELSE 5.-"
    .. "t%.due_date ASC NULLS LAST,%s+t%.created_at ASC") ~= nil)
check("limit/offset bound last", s.values[#s.values - 1] == 20 and s.values[#s.values] == 0)
check("count query: same filters, no limit/offset", #c.values == 2 and c.values[1] == 7
    and not c.sql:find("LIMIT", 1, true))
check("board_uuid and project_uuid selected", s.sql:find("b.uuid as board_uuid", 1, true)
    and s.sql:find("p.uuid as project_uuid", 1, true))

local due_sql = {
    today = "t.due_date = ?::date", overdue = "t.due_date < ?::date", today_and_overdue = "t.due_date <= ?::date",
    week = "t.due_date BETWEEN ?::date AND ?::date + 6", upcoming = "t.due_date >= ?::date",
    none = "t.due_date IS NULL",
}
for due, frag in pairs(due_sql) do
    run({ due = due, date = "2030-06-15" })
    s = last_select()
    local n = select(2, frag:gsub("%?", ""))
    local dates = 0
    for i = 4, #s.values - 2 do if s.values[i] == "2030-06-15" then dates = dates + 1 end end
    check("due=" .. due .. " -> " .. frag, s.sql:find(frag, 1, true) and dates == n, dates)
end

run({ priority = "high,critical", status = "blocked", project_uuid = "p-1", search = "50%_off' OR 1=1 --" }, 3, 10)
s = last_select()
local vals = {}
for i, v in ipairs(s.values) do vals[i] = getmetatable(v) == LIST and ("list:" .. table.concat(v.items, ",")) or v end
local joined = table.concat(vals, "|", 1, #vals)
check("priority/status bound as lists", joined:find("list:high,critical", 1, true)
    and joined:find("list:blocked", 1, true) and s.sql:find("COALESCE(t.priority, 'none') IN ?", 1, true))
check("project bound", s.sql:find("p.uuid = ?", 1, true) and joined:find("|p-1|", 1, true))
check("search: user text never in the SQL, LIKE wildcards escaped",
    not s.sql:find("OR 1=1", 1, true) and joined:find("%50\\%\\_off' OR 1=1 --%", 1, true))
check("page 3 of 10 -> offset 20", s.values[#s.values] == 20 and s.values[#s.values - 1] == 10)

print("Rows:")
rows = {
    { id = 1, uuid = "t-1", task_number = 14, title = "Fix login", priority = "high", status = "open",
      due_date = "2030-06-14", overdue = true, project_name = "Web", project_uuid = "p-1", board_uuid = "b-1",
      column_name = "To Do", description = "long text", time_spent_minutes = 0 },
    { id = 2, uuid = "t-2", task_number = 3, title = "Write docs", priority = "low", status = "review",
      overdue = false, project_name = "Docs", project_uuid = "p-2", board_uuid = "b-2", column_name = "Review" },
}
local r = run({ date = "2030-06-15" })
check("each item gets its task page url", r.data[1].url == "/dashboard/projects/p-1/tasks/t-1"
    and r.data[2].url == "/dashboard/projects/p-2/tasks/t-2")
check("result carries total and the date used", r.total == 2 and r.date == "2030-06-15")

print("Assistant tool list_my_tasks:")
local Tools = require("lib.agent.tools")
local granted = { namespace_id = 7, user_uuid = "user-1", has_permission = function(m, a)
    return m == "projects" and a == "read"
end }
calls = {}
local res, err = Tools.execute(granted, "list_my_tasks", { due = "today_and_overdue", date = "2030-06-15" })
check("runs", res ~= nil, err)
res = res or { tasks = {} }
local want = { "uuid", "task_number", "title", "priority", "status", "due_date", "overdue", "project",
    "project_uuid", "column", "url" }
local allowed_keys = {}
for _, k in ipairs(want) do allowed_keys[k] = true end
local t1 = res.tasks[1] or {}
local missing, extra = {}, {}
for _, k in ipairs(want) do if t1[k] == nil then missing[#missing + 1] = k end end
for k in pairs(t1) do if not allowed_keys[k] then extra[#extra + 1] = k end end
check("row has exactly the documented fields", #missing == 0 and #extra == 0,
    "missing " .. table.concat(missing, ",") .. " extra " .. table.concat(extra, ","))
check("row values", t1.task_number == 14 and t1.project == "Web" and t1.column == "To Do" and t1.overdue == true
    and t1.url == "/dashboard/projects/p-1/tasks/t-1")
check("overdue is a boolean even when false", res.tasks[2] and res.tasks[2].overdue == false)
check("result: tasks, total, date", #res.tasks == 2 and res.total == 2 and res.date == "2030-06-15")
check("due filter reached the SQL", last_select().sql:find("t.due_date <= ?::date", 1, true) ~= nil)

calls = {}
Tools.execute(granted, "list_my_tasks", { limit = 500 })
check("limit capped at 50", last_select().values[#last_select().values - 1] == 50)
Tools.execute(granted, "list_my_tasks", {})
check("default limit 20, no due filter (date, namespace, user, limit, offset)",
    last_select().values[#last_select().values - 1] == 20 and #last_select().values == 5)
Tools.execute(granted, "list_my_tasks", { limit = 0 / 0 })
check("NaN limit -> default", last_select().values[#last_select().values - 1] == 20)
Tools.execute(granted, "list_my_tasks", { project = "Web site" })
check("project by name -> project_name filter", last_select().sql:find("p.name ILIKE ?", 1, true) ~= nil)
Tools.execute(granted, "list_my_tasks", { project = "9e98ab27-846a-43c3-9473-64668b0c7859" })
check("project by uuid -> project_uuid filter", last_select().sql:find("p.uuid = ?", 1, true) ~= nil)

local none, bad = Tools.execute(granted, "list_my_tasks", { due = "yesterday" })
check("bad due -> a clean error for the model", none == nil and bad:find("due must be one of", 1, true), bad)
none, bad = Tools.execute(granted, "list_my_tasks", { priority = "urgent" })
check("bad priority -> a clean error", none == nil and bad:find("priority must be", 1, true), bad)
none, bad = Tools.execute({ namespace_id = 7, user_uuid = "u", has_permission = function() return false end },
    "list_my_tasks", {})
check("needs projects.read", none == nil and bad:find("permission", 1, true), bad)

print("Wiring:")
local route = read("lapis/routes/kanban-projects.lua")
local my = route:match('app:get%("/api/v2/kanban/my%-tasks".-\n    %)%)') or ""
check("route validates filters -> 400", my:find("parseMyTaskFilters(self.params)", 1, true)
    and my:find("api_response(400, nil, filter_err)", 1, true))
check("route: projects.read, per_page|perPage capped at 100", my:find('requirePermission("projects", "read"', 1, true)
    and my:find("Global.perPageParam(self.params.per_page or self.params.perPage, 20, 100)", 1, true))
check("route meta: per_page, total_pages, date (+ camelCase kept)", my:find("per_page = per_page", 1, true)
    and my:find("total_pages = total_pages", 1, true) and my:find("date = result.date", 1, true)
    and my:find("perPage = per_page", 1, true))
local m = read("lapis/migrations.lua")
check("menu migration gated on kanban",
    m:find('load_if_enabled(ProjectConfig.FEATURES.KANBAN, "migrations.my-tasks")', 1, true)
    and m:find("['zzmt1_my_tasks_menu'] = conditional_array(ProjectConfig.FEATURES.KANBAN, my_tasks_migrations, 1)",
        1, true))
local mig = read("lapis/migrations/my-tasks.lua")
check("menu item: key, path, icon, module, priority", mig:find('MENU_KEY = "my_tasks"', 1, true)
    and mig:find('path = "/dashboard/my-tasks"', 1, true) and mig:find('icon = "ListTodo"', 1, true)
    and mig:find('module = "projects"', 1, true) and mig:find("priority = 2,", 1, true))
check("menu migration is idempotent", mig:find("if not menu then", 1, true) and mig:find("WHERE NOT EXISTS", 1, true))
check("projects assistant serves the My Tasks page",
    read("lapis/lib/agent/knowledge/projects.md"):find("pages: /dashboard/projects, /dashboard/my-tasks", 1, true))

print(failures == 0 and "\nAll checks passed." or ("\n" .. failures .. " check(s) FAILED."))
os.exit(failures == 0 and 0 or 1)
