--[[
    Regression spec: Kanban real-time WebSocket wiring is intact.

    Standalone — no busted/luarocks needed. Run from the repo root with:
        luajit lapis/spec/kanban-realtime-ws_spec.lua

    Guards the moving parts of the live-board feature so they can't silently
    rot: the WS hub module's contract (auth + membership gate + the
    queue/semaphore fanout that keeps sends on the owning coroutine), the nginx
    location that runs it outside Lapis, the broadcast calls at each task
    mutation, and the frontend hook + its mount on the board page.
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

print("ws hub module:")
local ws = read("lapis/lib/kanban-ws.lua")
check("exports broadcast + handler",
    ws:match("function _M%.broadcast") ~= nil and ws:match("function _M%.handler") ~= nil)
check("uses resty.websocket.server", has(ws, 'require("resty.websocket.server")'))
check("uses ngx.semaphore for cross-request handoff", has(ws, 'require("ngx.semaphore")'))
check("verifies the JWT itself (runs outside Lapis auth)", has(ws, "jwt:verify"))
check("authorizes via project membership", has(ws, "KanbanProjectQueries.isMember"))
-- The fanout must never touch a socket from the mutation's coroutine: broadcast
-- only enqueues + posts the semaphore; the writer coroutine does the send.
check("broadcast enqueues (no direct socket send)", has(ws, "enqueue(conn"))
check("a writer coroutine owns send_text", has(ws, "wb:send_text"))

print("\nnginx location (both variants):")
for _, conf in ipairs({ "lapis/nginx.conf", "lapis/nginx-values-template.conf" }) do
    local c = read(conf)
    check(conf .. " routes the ws location to the hub",
        has(c, "location = /api/v2/kanban/ws") and has(c, 'require("lib.kanban-ws").handler()'))
end

print("\ntask mutations broadcast:")
local tasks = read("lapis/routes/kanban-tasks.lua")
check("requires the ws hub", has(tasks, 'require "lib.kanban-ws"'))
check("broadcast is best-effort (pcall)", tasks:match("function broadcast_board.-pcall") ~= nil)
for _, evt in ipairs({ "task:created", "task:updated", "task:deleted", "task:moved" }) do
    check("emits " .. evt, has(tasks, '"' .. evt .. '"'))
end

print("\nfrontend hook + mount:")
local hook = read("opsapi-dashboard/hooks/useKanbanSocket.ts")
check("hook gates on NEXT_PUBLIC_WS_URL", has(hook, "NEXT_PUBLIC_WS_URL"))
check("hook ignores the actor's own echo", has(hook, "actor_uuid"))
check("hook refetches the board on events", has(hook, "refreshBoardData"))
local page = read("opsapi-dashboard/app/dashboard/projects/[uuid]/page.tsx")
check("board page mounts useKanbanSocket", has(page, "useKanbanSocket(projectUuid)"))
check("hook is exported from the barrel", has(read("opsapi-dashboard/hooks/index.ts"), "useKanbanSocket"))

print("")
if failures > 0 then
    print(failures .. " failure(s)")
    os.exit(1)
end
print("all checks passed")
