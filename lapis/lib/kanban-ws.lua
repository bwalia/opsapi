--[[
    Kanban real-time WebSocket hub
    ==============================

    Live board sync: when someone moves/updates/creates/deletes a task, everyone
    viewing that project's board is pushed a compact event and refetches.

    Runs OUTSIDE Lapis (its own nginx `location`, see nginx.conf), so the global
    auth `before_filter` never runs for it — this handler verifies the JWT itself
    (from the `?token=` query param, since browsers can't set headers on a WS
    handshake) and re-checks project membership before joining a channel. The
    kanban tenant boundary is transitive project membership, so isMember() is the
    authorization gate (no namespace header is trusted here).

    Fanout model — the important OpenResty constraint:
      A cosocket is bound to the request that created it. You CANNOT call send()
      on a viewer's socket from another request's coroutine (the mutation). So a
      mutation never touches a socket: it enqueues an event onto each connection's
      Lua queue and posts that connection's semaphore (both legal cross-request),
      and every connection's own writer coroutine drains its queue and sends.

    Scale: prod is a single worker in a single pod (worker_processes 1,
    replicaCount 1), so this module-level registry sees every connection — no
    Redis needed. If workers or replicas ever scale, keep everything else and
    replace the body of broadcast() with a Redis PUBLISH + a per-connection
    SUBSCRIBE (the "send only from the owning coroutine" rule still holds).
]]

local ws_server = require("resty.websocket.server")
local semaphore = require("ngx.semaphore")
local cjson = require("cjson.safe")
local jwt = require("resty.jwt")
local Global = require("helper.global")
local db = require("lapis.db")
local KanbanProjectQueries = require("queries.KanbanProjectQueries")

local _M = {}

-- channels[project_id] = { [conn_id] = conn }
-- conn = { id, project_id, user_uuid, queue = {}, sem, closing }
local channels = {}
local next_id = 0

local MAX_QUEUE = 200        -- per-connection cap; drop oldest if a client stalls
local RECV_TIMEOUT_MS = 30000 -- socket read timeout; doubles as the writer keepalive tick
local PONG_FRAME = "\0pong"  -- internal marker: writer should emit a protocol pong

local function register(conn)
    local ch = channels[conn.project_id]
    if not ch then
        ch = {}
        channels[conn.project_id] = ch
    end
    ch[conn.id] = conn
end

local function unregister(conn)
    local ch = channels[conn.project_id]
    if ch then
        ch[conn.id] = nil
        if next(ch) == nil then
            channels[conn.project_id] = nil
        end
    end
end

-- Enqueue one frame for a connection and wake its writer. Legal to call from
-- any request (touches only Lua tables + the semaphore, never the socket).
local function enqueue(conn, frame)
    local q = conn.queue
    q[#q + 1] = frame
    if #q > MAX_QUEUE then
        table.remove(q, 1)
    end
    conn.sem:post()
end

--- Fan an event out to everyone watching `project_id`.
-- Called from the mutation request context. Safe: no socket access.
-- @param project_id number
-- @param event_type string  e.g. "task:moved"
-- @param data table         small payload (board_uuid, task_uuid, actor_uuid, …)
function _M.broadcast(project_id, event_type, data)
    if not project_id then return end
    local ch = channels[project_id]
    if not ch then return end
    local payload = cjson.encode({ type = event_type, data = data })
    if not payload then return end
    for _, conn in pairs(ch) do
        enqueue(conn, payload)
    end
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

-- Resolve a project uuid to its numeric id (no namespace trust; membership is
-- the authz gate below).
local function project_id_for(project_uuid)
    local rows = db.query(
        "SELECT id FROM kanban_projects WHERE uuid = ? AND deleted_at IS NULL LIMIT 1",
        project_uuid
    )
    return rows and rows[1] and rows[1].id or nil
end

--- nginx content handler for `location = /api/v2/kanban/ws`.
function _M.handler()
    local user = verify_token(ngx.var.arg_token)
    if not user then
        return ngx.exit(401)
    end
    local user_uuid = user.uuid or user.sub

    local project_uuid = ngx.var.arg_project
    if not project_uuid or project_uuid == "" then
        return ngx.exit(400)
    end
    local project_id = project_id_for(project_uuid)
    if not project_id or not KanbanProjectQueries.isMember(project_id, user_uuid) then
        return ngx.exit(403)
    end

    local wb, err = ws_server:new({ timeout = RECV_TIMEOUT_MS, max_payload_len = 65535 })
    if not wb then
        ngx.log(ngx.ERR, "[kanban-ws] handshake failed: ", err)
        return ngx.exit(444)
    end

    next_id = next_id + 1
    local conn = {
        id = next_id,
        project_id = project_id,
        user_uuid = user_uuid,
        queue = {},
        sem = semaphore.new(),
        closing = false,
    }
    register(conn)

    -- Reader: process inbound frames. Never sends (single-writer rule); it
    -- enqueues any reply for the writer instead.
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
            -- data == nil with no fatal == read timeout: just loop
        end
    end

    -- Writer: the ONLY coroutine that writes to the socket.
    local function writer()
        local _, gerr = wb:send_text(
            cjson.encode({ type = "connected", data = { project = project_uuid } })
        )
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
                -- idle: app-level keepalive so proxies/CDN don't cull the socket
                local _, serr = wb:send_ping()
                if serr then
                    conn.closing = true
                end
            end
        end
    end

    local rco = ngx.thread.spawn(reader)
    local wco = ngx.thread.spawn(writer)
    ngx.thread.wait(rco, wco) -- returns as soon as either coroutine exits
    conn.closing = true
    conn.sem:post()           -- unblock the writer if it is waiting
    ngx.thread.kill(rco)
    ngx.thread.kill(wco)
    unregister(conn)
    pcall(function() wb:send_close() end)
    return ngx.exit(200)
end

return _M
