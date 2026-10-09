--[[
    Regression spec: chat WebSocket delivery across pods (Redis pub/sub).

    Standalone — no busted/luarocks needed. Run from the repo root with:
        luajit lapis/spec/chat-pubsub_spec.lua

    The live proof is spec/chat-pubsub-e2e/run.sh (two app processes, one
    Redis, a WebSocket client on each). This guards the invariants it relies on
    (CHAT_SCALING_RUNBOOK.md §4): only the connection's own writer sends; the
    publish and subscriber paths only enqueue; the queue stays bounded; a pod
    skips what it published itself; Redis off means local-only.
]]

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
local function has(s, needle) return s:find(needle, 1, true) ~= nil end
-- The body of `function name(` up to the next top-level `end`.
local function body(src, name)
    local i = src:find("function " .. name .. "(", 1, true)
    if not i then return "" end
    return src:sub(i, src:find("\nend\n", i, true) or #src)
end

local ws = read("lapis/lib/chat-ws.lua")
local handler_at = ws:find("function _M.handler(", 1, true)

print("single writer:")
local early_send
for pos in ws:gmatch("()wb:send") do
    if pos < handler_at then early_send = pos end
end
check("no socket send outside handler()", handler_at and not early_send, early_send)
for _, fn in ipairs({ "_M.broadcast", "_M.push_user", "deliver", "publish", "subscribe" }) do
    local b = body(ws, fn)
    check(fn .. " never touches a socket", b ~= "" and not b:find("wb:", 1, true) and not b:find("send_", 1, true))
end
check("enqueue keeps MAX_QUEUE backpressure", body(ws, "enqueue"):find("#q > MAX_QUEUE", 1, true) ~= nil)

print("cross-pod delivery:")
local bc, pu = body(ws, "_M.broadcast"), body(ws, "_M.push_user")
check("broadcast delivers on this pod, then publishes",
    bc:find("push_to_user", 1, true) and bc:find("publish(", 1, true)
    and bc:find("push_to_user", 1, true) < bc:find("publish(", 1, true))
check("broadcast keys the publish by namespace + channel", has(bc, 'data.namespace_id or "-") .. ":" .. channel_uuid'))
check("broadcast: one membership query per message, none per subscriber",
    select(2, bc:gsub("db%.query", "")) == 1 and not body(ws, "deliver"):find("db.", 1, true))
check("push_user (agent:done) also crosses pods", has(pu, "push_to_user(") and has(pu, 'publish("user:"'))
check("a pod skips what it published itself", has(body(ws, "deliver"), "m.o == origin()"))
check("deliver only enqueues", has(body(ws, "deliver"), "push_to_user(user_uuid, m.f)"))

print("Redis down / off:")
local pub, sub = body(ws, "publish"), body(ws, "subscribe")
check("publish is a no-op when REDIS_ENABLED=false", has(pub, "if not RedisClient.enabled() then return end"))
check("publish failure logs a rate-limited WARN, never raises",
    has(pub, "ngx.WARN") and has(pub, "publish_warned_at >= 60") and not has(pub, "error("))
check("start() is a no-op when REDIS_ENABLED=false", has(body(ws, "_M.start"), "if not RedisClient.enabled() then return end"))
check("subscriber never returns its connection to the pool",
    has(sub, "red:close()") and not has(sub, "RedisClient.release"))
check("subscriber detects a dead link (heartbeat + read timeout)",
    has(ws, "ngx.timer.every(HEARTBEAT_S") and has(sub, "set_timeouts(1000, 1000, STALE_MS)"))
check("one WARN per outage, then backoff", has(body(ws, "run"), "if was_up or backoff == 0 then")
    and has(body(ws, "run"), "MAX_BACKOFF_S"))

print("wiring:")
for _, conf in ipairs({ "lapis/nginx.conf", "lapis/nginx-values-template.conf" }) do
    local c = read(conf)
    local iw = c:sub(c:find("init_worker_by_lua_block", 1, true) or 1)
    check(conf .. " starts the subscriber in init_worker", has(iw:sub(1, (iw:find("\n    }\n", 1, true) or #iw)),
        'require("lib.chat-ws").start()'))
end
check("redis-client skips AUTH on a pooled connection",
    has(read("lapis/helper/redis-client.lua"), "get_reused_times()"))

print(failures == 0 and "\nall chat pub/sub checks passed" or ("\n" .. failures .. " check(s) FAILED"))
os.exit(failures == 0 and 0 or 1)
