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

    Scale: prod is a single worker in a single pod (worker_processes 1,
    replicaCount 1) with lua_code_cache on, so this module-level registry sees
    every connection — no Redis needed. If workers/replicas ever scale, keep
    everything else and replace broadcast()'s fanout with Redis PUBLISH + a
    per-connection SUBSCRIBE (the "send only from the owning coroutine" rule
    still holds).
]]

local ws_server = require("resty.websocket.server")
local semaphore = require("ngx.semaphore")
local cjson = require("cjson.safe")
local jwt = require("resty.jwt")
local Global = require("helper.global")
local db = require("lapis.db")

local _M = {}

-- connections[user_uuid] = { [conn_id] = conn }
-- conn = { id, user_uuid, queue = {}, sem, closing }
local connections = {}
local next_id = 0

local MAX_QUEUE = 200
local RECV_TIMEOUT_MS = 30000
local PONG_FRAME = "\0pong"

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

--- Fan an event out to every connected member of a channel.
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
    for _, m in ipairs(members or {}) do
        if connections[m.user_uuid] then
            push_to_user(m.user_uuid, frame)
        end
    end
end

--- Push a new message to a channel's connected members.
-- @param namespace_id number|nil  so the client can ignore other-tenant tabs
-- @param message table            the full message row (with sender info)
function _M.broadcast_message(channel_uuid, namespace_id, message)
    _M.broadcast(channel_uuid, "message:new", {
        channel_uuid = channel_uuid,
        namespace_id = namespace_id,
        message = message,
    })
end

-- Verify the JWT from the ?token param. Mirrors middleware/auth.lua's core.
local function verify_token(token)
    if not token or token == "" then return nil end
    local secret = Global.getEnvVar("JWT_SECRET_KEY")
    if not secret then return nil end
    local obj = jwt:verify(secret, token)
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
