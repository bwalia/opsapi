--[[
    Chat real-time WebSocket hub
    ============================

    Live message delivery: when someone posts to a channel or DM, every member
    who has this socket open is pushed a compact event and reacts (append if the
    channel is open, else bump unread + toast).

    Mirrors lib/kanban-ws.lua — read its header for the OpenResty constraints
    (cosocket is bound to its own request; a mutation must NOT touch another
    request's socket, so broadcast() only enqueues onto each connection's Lua
    queue + posts its semaphore, and each connection's writer drains + sends).

    Difference from kanban: kanban subscribes per *project*; chat subscribes per
    *user*. A connection represents "this person is online in chat", and a
    message to any channel they belong to is pushed to them — that's how a DM
    started in a channel you don't currently have open still notifies you.

    Runs OUTSIDE Lapis (own nginx `location`, see nginx.conf), so the global auth
    before_filter never runs: this handler verifies the ?token= JWT itself
    (browsers can't set headers on a WS handshake). Delivery authorization is
    channel membership, checked at broadcast time from chat_channel_members.

    Scale: every pod (and every nginx worker) keeps its own registry of the
    sockets it holds. A message reaches the other pods through Redis pub/sub
    (CHAT_SCALING_RUNBOOK.md §1): the pod that handles the send delivers to its
    own connections directly, then PUBLISHes the frame + recipient list to
    opsapi:chat:<namespace_id>:<channel_uuid>. Every worker runs one subscriber
    (start(), from init_worker) on opsapi:chat:* that enqueues onto ITS local
    connections and skips what it published itself, so nothing arrives twice.
    The single-writer rule holds on both paths: only enqueue + sem:post.
    Redis down or REDIS_ENABLED=false: delivery stays on this pod (as before
    pub/sub), a WARN says so, and a send never fails because of it.
]]

local ws_server = require("resty.websocket.server")
local semaphore = require("ngx.semaphore")
local cjson = require("cjson.safe")
local Global = require("helper.global")
local db = require("lapis.db")
local RedisClient = require("helper.redis-client")

local _M = {}

-- connections[user_uuid] = { [conn_id] = conn }
-- conn = { id, user_uuid, queue = {}, sem, closing }
local connections = {}
local next_id = 0

local MAX_QUEUE = 200
local RECV_TIMEOUT_MS = 30000
local PONG_FRAME = "\0pong"

-- Cross-pod delivery (Redis pub/sub)
local PREFIX = "opsapi:chat:"
local HEARTBEAT_S = 10      -- the subscriber hears its own heartbeat this often...
local STALE_MS = 35000      -- ...so this long without any traffic means a dead link
local MAX_BACKOFF_S = 30
local worker_id             -- tags what this worker publishes; its subscriber skips those
local subscribed = false
local publish_warned_at = 0

local function register(conn)
    local set = connections[conn.user_uuid]
    if not set then
        set = {}
        connections[conn.user_uuid] = set
    end
    set[conn.id] = conn
end

local function unregister(conn)
    local set = connections[conn.user_uuid]
    if set then
        set[conn.id] = nil
        if next(set) == nil then
            connections[conn.user_uuid] = nil
        end
    end
end

-- Enqueue one frame and wake the connection's writer. Legal from any request
-- (touches only Lua tables + the semaphore, never the socket).
local function enqueue(conn, frame)
    local q = conn.queue
    q[#q + 1] = frame
    if #q > MAX_QUEUE then
        table.remove(q, 1)
    end
    conn.sem:post()
end

-- Push a frame to every open connection of a user (all their tabs).
local function push_to_user(user_uuid, frame)
    local set = connections[user_uuid]
    if not set then return end
    for _, conn in pairs(set) do
        enqueue(conn, frame)
    end
end

-- Per-worker subscription state, in shared memory so /ready (served by any
-- worker) sees every worker's subscriber (nginx.conf: lua_shared_dict chat_ws).
local function set_subscribed(up)
    subscribed = up
    local dict = ngx.shared.chat_ws
    if dict and ngx.worker.id() then dict:set("sub:" .. ngx.worker.id(), up) end
end

local function origin()
    if not worker_id then
        worker_id = string.format("%s:%d:%d", os.getenv("HOSTNAME") or "", ngx.worker.pid(),
            math.floor(ngx.now() * 1000))
    end
    return worker_id
end

-- Hand a frame to the other pods. Never raises: the caller has already
-- delivered on this pod, so a Redis failure only costs cross-pod delivery.
local function publish(key, users, frame)
    if not RedisClient.enabled() then return end
    local red = RedisClient.connect()
    local ok, err = false, "Redis unreachable"
    if red then
        ok, err = red:publish(PREFIX .. key, cjson.encode({ o = origin(), u = users, f = frame }))
        if ok then RedisClient.release(red) else red:close() end
    end
    if not ok and ngx.now() - publish_warned_at >= 60 then
        publish_warned_at = ngx.now()
        ngx.log(ngx.WARN, "[chat-ws] PUBLISH failed (", tostring(err), "); delivering on this pod only")
    end
end

--- Fan an event out to every connected member of a channel, on every pod.
-- Called from a mutation request. Safe: only Lua tables + semaphores, never a
-- foreign socket. @param event_type e.g. "message:new" | "reaction:update".
function _M.broadcast(channel_uuid, event_type, data)
    if not channel_uuid then return end
    local frame = cjson.encode({ type = event_type, data = data })
    if not frame then return end

    local members = db.query(
        "SELECT user_uuid FROM chat_channel_members WHERE channel_uuid = ? AND left_at IS NULL",
        channel_uuid
    )
    local users = {}
    for i, m in ipairs(members or {}) do
        users[i] = m.user_uuid
        push_to_user(m.user_uuid, frame)
    end
    -- ponytail: the recipient list rides in the message (subscribers do no DB
    -- work); ~40 bytes a member, so switch to a per-pod membership lookup if
    -- channels reach tens of thousands of members.
    if #users > 0 then
        publish(tostring(data and data.namespace_id or "-") .. ":" .. channel_uuid, users, frame)
    end
end

--- Push an event to one user's open connections (all their tabs, any pod),
-- e.g. "agent:done" from the background agent run. Same enqueue-only safety
-- as broadcast(), so it's legal from a timer.
function _M.push_user(user_uuid, event_type, data)
    local frame = user_uuid and cjson.encode({ type = event_type, data = data })
    if not frame then return end
    push_to_user(user_uuid, frame)
    publish("user:" .. user_uuid, { user_uuid }, frame)
end

--- Push a new message to a channel's connected members.
-- @param namespace_id number|nil  so the client can ignore other-tenant tabs
-- @param message table            the full message row (with sender info)
-- @param channel table|nil        {name, type} so notifications can say where
--                                 it came from ("in #general" vs a DM)
function _M.broadcast_message(channel_uuid, namespace_id, message, channel)
    _M.broadcast(channel_uuid, "message:new", {
        channel_uuid = channel_uuid,
        namespace_id = namespace_id,
        channel_name = channel and channel.name or nil,
        channel_type = channel and channel.type or nil,
        message = message,
    })
end

-- Subscriber side: a frame another worker published. Enqueue only.
local function deliver(payload)
    local m = cjson.decode(payload)
    if type(m) ~= "table" or m.o == origin() or type(m.f) ~= "string" or type(m.u) ~= "table" then return end
    for _, user_uuid in ipairs(m.u) do
        push_to_user(user_uuid, m.f)
    end
end

-- One subscription, held until the link drops. A pubsub connection can't go
-- back to the keepalive pool, so it is always closed. @return was_up, err
local function subscribe()
    local red = RedisClient.connect()
    if not red then return false, "Redis unreachable" end
    red:set_timeouts(1000, 1000, STALE_MS)
    local ok, err = red:psubscribe(PREFIX .. "*")
    if not ok then
        red:close()
        return false, "PSUBSCRIBE failed: " .. tostring(err)
    end
    set_subscribed(true)
    ngx.log(ngx.NOTICE, "[chat-ws] subscribed to Redis; chat delivery spans pods")
    while not ngx.worker.exiting() do
        local res, rerr = red:read_reply()
        if not res then
            err = rerr
            break
        end
        if res[1] == "pmessage" then deliver(res[4]) end
    end
    set_subscribed(false)
    red:close()
    return true, err
end

-- One WARN per outage; reconnect at once after a working link, then back off.
local function run(premature, backoff)
    if premature or ngx.worker.exiting() then return end
    local was_up, err = subscribe()
    if ngx.worker.exiting() then return end
    if was_up or backoff == 0 then
        ngx.log(ngx.WARN, "[chat-ws] Redis subscriber down (", tostring(err),
            "); chat delivery is local to this pod until it reconnects")
    end
    backoff = was_up and 1 or math.min(math.max(backoff, 1) * 2, MAX_BACKOFF_S)
    ngx.timer.at(was_up and 0 or backoff, run, backoff)
end

--- Start this worker's subscriber (init_worker). No-op when REDIS_ENABLED=false.
function _M.start()
    if not RedisClient.enabled() then return end
    origin()
    set_subscribed(false)
    ngx.timer.at(0, run, 0)
    -- Keeps the link provably alive: the subscriber hears this within
    -- HEARTBEAT_S, or read_reply times out at STALE_MS and it reconnects.
    ngx.timer.every(HEARTBEAT_S, function(premature)
        if not premature and subscribed then publish("hb:" .. origin(), {}, "") end
    end)
end

--- Readiness (GET /ready): whether every worker of this pod holds its Redis
-- subscription, i.e. receives chat events sent through other pods.
function _M.subscribed()
    local dict = ngx.shared.chat_ws
    if not dict then return subscribed end
    for id = 0, ngx.worker.count() - 1 do
        if not dict:get("sub:" .. id) then return false end
    end
    return true
end

-- Verify the JWT from the ?token param. Mirrors middleware/auth.lua's core.
local function verify_token(token)
    if not token or token == "" then return nil end
    local secret = Global.getEnvVar("JWT_SECRET_KEY")
    if not secret then return nil end
    local obj = require("helper.jwt-verify")(secret, token)
    if not obj or not obj.verified then return nil end
    local ui = obj.payload and obj.payload.userinfo
    if not ui or (not ui.uuid and not ui.sub) then return nil end
    return ui
end

--- nginx content handler for `location = /api/chat/ws`.
function _M.handler()
    local user = verify_token(ngx.var.arg_token)
    if not user then
        return ngx.exit(401)
    end
    local user_uuid = user.uuid or user.sub

    local wb, err = ws_server:new({ timeout = RECV_TIMEOUT_MS, max_payload_len = 65535 })
    if not wb then
        ngx.log(ngx.ERR, "[chat-ws] handshake failed: ", err)
        return ngx.exit(444)
    end

    next_id = next_id + 1
    local conn = {
        id = next_id,
        user_uuid = user_uuid,
        queue = {},
        sem = semaphore.new(),
        closing = false,
    }
    register(conn)

    -- Reader: never sends (single-writer rule); enqueues replies for the writer.
    local function reader()
        while not conn.closing do
            local data, typ = wb:recv_frame()
            if wb.fatal then
                return
            end
            if typ == "close" then
                return
            elseif typ == "ping" then
                enqueue(conn, PONG_FRAME)
            elseif typ == "text" and data then
                local msg = cjson.decode(data)
                if msg and msg.type == "ping" then
                    enqueue(conn, cjson.encode({ type = "pong" }))
                end
                -- server is push-only; any other client message is ignored
            end
        end
    end

    -- Writer: the ONLY coroutine that writes to the socket.
    local function writer()
        local _, gerr = wb:send_text(cjson.encode({ type = "connected" }))
        if gerr then
            conn.closing = true
            return
        end
        while not conn.closing do
            local ok = conn.sem:wait(RECV_TIMEOUT_MS / 1000)
            if conn.closing then break end
            if ok then
                local q = conn.queue
                conn.queue = {}
                for _, frame in ipairs(q) do
                    local serr
                    if frame == PONG_FRAME then
                        _, serr = wb:send_pong()
                    else
                        _, serr = wb:send_text(frame)
                    end
                    if serr then
                        conn.closing = true
                        break
                    end
                end
            else
                local _, serr = wb:send_ping()
                if serr then
                    conn.closing = true
                end
            end
        end
    end

    local rco = ngx.thread.spawn(reader)
    local wco = ngx.thread.spawn(writer)
    ngx.thread.wait(rco, wco)
    conn.closing = true
    conn.sem:post()
    ngx.thread.kill(rco)
    ngx.thread.kill(wco)
    unregister(conn)
    pcall(function() wb:send_close() end)
    return ngx.exit(200)
end

return _M
