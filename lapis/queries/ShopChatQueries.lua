-- luacheck: max line length 140
--[[
    Shop AI-agent chat transcripts
    ==============================
    The shop BFF creates a session and appends each completed turn (user text,
    assistant text, tool names) so the back office can review conversations.
]]

local db = require("lapis.db")
local unpack = unpack or table.unpack -- luacheck: ignore 113 143
local cjson = require("cjson")
local Global = require("helper.global")
local U = require("lib.shop-util")
local Cart = require("queries.ShopCartQueries")

local ShopChatQueries = {}

local MAX_CONTENT = 8000
local MAX_PER_CALL = 50
local MAX_MESSAGES = 1000
local ROLES = { user = true, assistant = true, system = true, tool = true }

function ShopChatQueries.create(ns_id, body)
    body = body or {}
    local cart
    if U.nz(body.cart_token) then cart = Cart.byToken(ns_id, body.cart_token) end
    local row = db.query([[
        INSERT INTO shop_chat_sessions (uuid, namespace_id, cart_id, email, messages, message_count, created_at, updated_at)
        VALUES (?, ?, ?, ?, '[]'::jsonb, 0, NOW(), NOW()) RETURNING id, uuid
    ]], Global.generateUUID(), ns_id, cart and cart.id or db.NULL, U.nz(body.email) or db.NULL)[1]
    if cart then
        db.query("UPDATE shop_carts SET chat_session_id = ? WHERE id = ? AND chat_session_id IS NULL", row.id, cart.id)
    end
    return { uuid = row.uuid }
end

function ShopChatQueries.append(ns_id, uuid, body)
    local s = db.query("SELECT id, message_count FROM shop_chat_sessions WHERE namespace_id = ? AND uuid = ?",
        ns_id, uuid)[1]
    if not s then return nil, U.err(404, "CHAT_SESSION_NOT_FOUND", "Chat session not found") end
    local msgs = type(body.messages) == "table" and body.messages or nil
    if not msgs or #msgs == 0 then return nil, U.err(400, "VALIDATION_ERROR", "messages must be a non-empty array") end
    if #msgs > MAX_PER_CALL then return nil, U.err(400, "VALIDATION_ERROR", "too many messages in one call") end
    if (tonumber(s.message_count) or 0) + #msgs > MAX_MESSAGES then
        return nil, U.err(409, "TRANSCRIPT_FULL", "This chat transcript is full")
    end
    local now = os.date("!%Y-%m-%dT%H:%M:%SZ")
    local clean = {}
    for _, m in ipairs(msgs) do
        if type(m) == "table" and ROLES[m.role] then
            local entry = { role = m.role, content = tostring(m.content == cjson.null and "" or (m.content or "")):sub(1, MAX_CONTENT),
                at = U.nz(m.at) or now }
            if type(m.tools) == "table" then
                local tools = {}
                for _, t in ipairs(m.tools) do
                    if type(t) == "string" then tools[#tools + 1] = t:sub(1, 64)
                    elseif type(t) == "table" and U.nz(t.name) then tools[#tools + 1] = tostring(t.name):sub(1, 64) end
                end
                entry.tools = U.arr(tools)
            end
            clean[#clean + 1] = entry
        end
    end
    if #clean == 0 then return nil, U.err(400, "VALIDATION_ERROR", "no valid messages (role must be user|assistant)") end
    local row = db.query([[
        UPDATE shop_chat_sessions SET messages = messages || ?::jsonb, message_count = message_count + ?,
               email = COALESCE(email, ?), updated_at = NOW()
         WHERE id = ? RETURNING uuid, message_count
    ]], U.enc(U.arr(clean)), #clean, U.nz(body.email) or db.NULL, s.id)[1]
    return { uuid = row.uuid, message_count = row.message_count }
end

local LIST_COLS = [[
    s.uuid, s.email, s.summary, s.message_count, s.created_at, s.updated_at,
    c.uuid AS cart_uuid, q.uuid AS quote_uuid, q.quote_number, o.uuid AS order_uuid, o.order_number
]]

function ShopChatQueries.adminList(ns_id, params)
    params = params or {}
    local limit = U.clamp(U.int(params.limit, 25), 1, 200)
    local offset = math.max(0, U.int(params.offset, 0))
    local where, vals = { "s.namespace_id = ?" }, { ns_id }
    if U.nz(params.q) then
        where[#where + 1] = "(s.email ILIKE ? OR s.messages::text ILIKE ?)"
        local like = "%" .. tostring(params.q):gsub("[%%_\\]", "\\%0") .. "%"
        vals[#vals + 1] = like
        vals[#vals + 1] = like
    end
    if U.bool(params.with_messages_only, false) then where[#where + 1] = "s.message_count > 0" end
    vals[#vals + 1] = limit
    vals[#vals + 1] = offset
    local rows = db.query("SELECT " .. LIST_COLS .. [[,
               (SELECT m->>'content' FROM jsonb_array_elements(s.messages) m WHERE m->>'role' = 'user' LIMIT 1)
                   AS first_user_message,
               COUNT(*) OVER() AS total
          FROM shop_chat_sessions s
          LEFT JOIN shop_carts c ON c.id = s.cart_id
          LEFT JOIN shop_quotes q ON q.id = s.quote_id
          LEFT JOIN shop_orders o ON o.id = s.order_id
         WHERE ]] .. table.concat(where, " AND ") .. " ORDER BY s.updated_at DESC, s.id DESC LIMIT ? OFFSET ?",
        unpack(vals))
    local total = rows[1] and tonumber(rows[1].total) or 0
    for _, r in ipairs(rows) do
        r.total = nil
        if r.first_user_message then r.first_user_message = r.first_user_message:sub(1, 200) end
        for _, k in ipairs({ "email", "summary", "cart_uuid", "quote_uuid", "quote_number", "order_uuid",
                             "order_number", "first_user_message" }) do
            if r[k] == nil then r[k] = U.null end
        end
    end
    return U.arr(rows), { total = total, limit = limit, offset = offset }
end

function ShopChatQueries.adminGet(ns_id, uuid)
    local r = db.query("SELECT " .. LIST_COLS .. [[, s.messages::text AS messages
          FROM shop_chat_sessions s
          LEFT JOIN shop_carts c ON c.id = s.cart_id
          LEFT JOIN shop_quotes q ON q.id = s.quote_id
          LEFT JOIN shop_orders o ON o.id = s.order_id
         WHERE s.namespace_id = ? AND s.uuid = ?]], ns_id, uuid)[1]
    if not r then return nil end
    r.messages = U.arr(U.dec(r.messages, {}))
    for _, k in ipairs({ "email", "summary", "cart_uuid", "quote_uuid", "quote_number", "order_uuid", "order_number" }) do
        if r[k] == nil then r[k] = U.null end
    end
    return r
end

return ShopChatQueries
