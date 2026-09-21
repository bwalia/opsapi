--[[
    Regression spec: Kanban mutations actually EMIT notifications.

    Standalone — no busted/luarocks needed. Run from the repo root with:
        luajit lapis/spec/kanban-notification-emit_spec.lua

    KanbanNotificationQueries.notify* were dead code: fully implemented but
    never called, so `kanban_notifications` stayed empty and the notification
    bell never populated. This guards against that regressing — the four
    mutation handlers (assign, comment, status->completed, project member added)
    must each call the matching notify* helper, via the pcall-wrapped
    notify_safe so a notification failure can never break the mutation.
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
local function has(s, needle)
    return s:find(needle, 1, true) ~= nil
end

print("tasks routes:")
local tasks = read("lapis/routes/kanban-tasks.lua")
check("requires KanbanNotificationQueries", has(tasks, 'require "queries.KanbanNotificationQueries"'))
check("notify_safe is pcall-wrapped", tasks:match("function notify_safe.-pcall") ~= nil)
check("assign emits notifyTaskAssigned", has(tasks, 'notify_safe("notifyTaskAssigned"'))
check("comment emits notifyTaskCommented", has(tasks, 'notify_safe("notifyTaskCommented"'))
check("status change emits notifyTaskStatusChanged", has(tasks, 'notify_safe("notifyTaskStatusChanged"'))
-- The status emit must be guarded on an actual change, not fired on every PUT.
check("status emit is guarded on a real change",
    has(tasks, "update_params.status ~= task.status"))

print("\nprojects routes:")
local projects = read("lapis/routes/kanban-projects.lua")
check("requires KanbanNotificationQueries", has(projects, 'require "queries.KanbanNotificationQueries"'))
check("add-member emits notifyProjectInvited", has(projects, 'notify_safe("notifyProjectInvited"'))

print("\nfrontend service paths:")
local svc = read("opsapi-dashboard/services/notification.service.ts")
-- These were the wrong paths/shapes that silently returned nothing.
check("mark-all-read uses the real route", has(svc, "/api/v2/kanban/notifications/mark-all-read"))
check("preferences use notification-preferences", has(svc, "/api/v2/kanban/notification-preferences"))
check("does NOT use the dead read-all route", not has(svc, "notifications/read-all"))
check("unread count reads unread_count field", has(svc, "response.data.data.unread_count"))

print("")
if failures > 0 then
    print(failures .. " failure(s)")
    os.exit(1)
end
print("all checks passed")
