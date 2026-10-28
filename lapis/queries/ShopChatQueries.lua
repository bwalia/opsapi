-- luacheck: max line length 140
--[[
    Shop AI-agent chat transcripts
    ==============================
    The shop BFF creates a session and appends each completed turn (user text,
    assistant text, tool names) so the back office can review conversations.

    The AI advisor also records what the customer needs (requirements) and,
    when the customer saves the chat with their email, links it to their CRM
    lead (ShopLeadQueries) with their explicit improve-advice consent choice.
]]

local db = require("lapis.db")
local unpack = unpack or table.unpack -- luacheck: ignore 113 143
local cjson = require("cjson")
local Global = require("helper.global")
local U = require("lib.shop-util")
local Cart = require("queries.ShopCartQueries")
local Leads = require("queries.ShopLeadQueries")
local L = require("lib.shop-leads")

local ShopChatQueries = {}

local MAX_CONTENT = 8000
local MAX_PER_CALL = 50
local MAX_MESSAGES = 1000
local ROLES = { user = true, assistant = true, system = true, tool = true }

local function short(v, max)
    v = U.nz(v)
    return v and tostring(v):gsub("^%s+", ""):gsub("%s+$", ""):sub(1, max) or nil
end

-- Name and phone from the customer's most recent CRM lead, when they didn't give them.
local function lead_contact(ns_id, email)
    local r = db.query([[
        SELECT TRIM(CONCAT_WS(' ', NULLIF(first_name, 'Shop customer'), last_name)) AS name, phone FROM crm_leads
         WHERE namespace_id = ? AND lower(email) = ? AND deleted_at IS NULL
         ORDER BY updated_at DESC NULLS LAST, id DESC LIMIT 1
    ]], ns_id, email)[1]
    if not r then return nil, nil end
    return short(r.name, 200), short(r.phone, 64)
end

--- Start a transcript.
-- body:    { cart_token?, email?, name?, phone? }
-- visitor: set by the route, never from the body: { client_ip?, country?, is_member? }
function ShopChatQueries.create(ns_id, body, visitor)
    body = body or {}
    visitor = visitor or {}
    local cart
    if U.nz(body.cart_token) then cart = Cart.byToken(ns_id, body.cart_token) end
    local email = L.email(body.email)
    local name, phone = short(body.name, 200), short(body.phone, 64)
    if email and (not name or not phone) then
        local lead_name, lead_phone = lead_contact(ns_id, email)
        name, phone = name or lead_name, phone or lead_phone
    end
    local country = type(visitor.country) == "string" and visitor.country:upper() or nil
    if country and not country:match("^%u%u$") then country = nil end
    -- The transcript opens with who started it, so it reads correctly wherever it is shown.
    local opening = {}
    if email then
        local who = { email }
        if name then who[#who + 1] = name end
        if phone then who[#who + 1] = phone end
        if visitor.is_member then who[#who + 1] = "signed-in member" end
        opening[1] = { role = "system", content = "Chat started by " .. table.concat(who, " · "),
            at = os.date("!%Y-%m-%dT%H:%M:%SZ") }
    end
    local row = db.query([[
        INSERT INTO shop_chat_sessions (uuid, namespace_id, cart_id, email, contact_name, contact_phone, client_ip,
                                        country, is_member, messages, message_count, created_at, updated_at)
        VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?::jsonb, ?, NOW(), NOW()) RETURNING id, uuid
    ]], Global.generateUUID(), ns_id, cart and cart.id or db.NULL, email or db.NULL, name or db.NULL,
        phone or db.NULL, short(visitor.client_ip, 64) or db.NULL, country or db.NULL, visitor.is_member == true,
        U.enc(U.arr(opening)), #opening)[1]
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

local function session_by_uuid(ns_id, uuid)
    return db.query([[
        SELECT id, uuid, email, requirements::text AS requirements, crm_lead_id,
               (SELECT m->>'content' FROM jsonb_array_elements(messages) m WHERE m->>'role' = 'user' LIMIT 1) AS first_user_message
          FROM shop_chat_sessions WHERE namespace_id = ? AND uuid = ?
    ]], ns_id, uuid)[1]
end

--- Merge what the customer said they need into the session (and their lead, if known).
function ShopChatQueries.recordRequirements(ns_id, uuid, body)
    local s = session_by_uuid(ns_id, uuid)
    if not s then return nil, U.err(404, "CHAT_SESSION_NOT_FOUND", "Chat session not found") end
    local incoming = L.requirements(type(body) == "table" and body.requirements or nil)
    if next(incoming) == nil then
        return nil, U.err(400, "VALIDATION_ERROR", "requirements must include at least one of: "
            .. table.concat(L.REQUIREMENT_KEYS, ", "))
    end
    local merged = L.merge_requirements(U.dec(s.requirements, {}), incoming)
    db.query("UPDATE shop_chat_sessions SET requirements = ?::jsonb, updated_at = NOW() WHERE id = ?", U.enc(merged), s.id)
    if U.nz(s.email) then
        Leads.safeUpsert(ns_id, { email = s.email, source = "shop_ai_advisor", chat_session_uuid = s.uuid,
            requirements = merged })
    end
    return { requirements = merged }
end

--- Customer saves the chat: link it to their email + CRM lead and record their consent choice.
-- body: { email, name?, company?, phone?, improve_consent: boolean }
function ShopChatQueries.saveContact(ns_id, uuid, body)
    body = type(body) == "table" and body or {}
    local email = L.email(body.email)
    if not email then return nil, U.err(400, "VALIDATION_ERROR", "Please enter a valid email address") end
    local s = session_by_uuid(ns_id, uuid)
    if not s then return nil, U.err(404, "CHAT_SESSION_NOT_FOUND", "Chat session not found") end
    local consent = body.improve_consent == true
    local req = U.dec(s.requirements, {})
    local note_parts = { "AI advisor chat saved by the customer" }
    local line = L.requirements_line(req)
    if line ~= "" then note_parts[#note_parts + 1] = line
    elseif U.nz(s.first_user_message) then note_parts[#note_parts + 1] = "First message: " .. s.first_user_message:sub(1, 300) end
    local lead = Leads.safeUpsert(ns_id, {
        email = email, name = body.name, company = body.company, phone = body.phone, source = "shop_ai_advisor",
        note = table.concat(note_parts, " — "), chat_session_uuid = s.uuid, requirements = req,
        improve_consent = consent,
    })
    db.query([[
        UPDATE shop_chat_sessions SET email = ?, improve_consent = ?, consent_at = NOW(),
               crm_lead_id = COALESCE(?, crm_lead_id), updated_at = NOW()
         WHERE id = ?
    ]], email, consent, lead and lead.id or db.NULL, s.id)
    return { saved = true, improve_consent = consent }
end

local LIST_COLS = [[
    s.uuid, s.email, s.summary, s.message_count, s.created_at, s.updated_at,
    s.contact_name, s.contact_phone, s.client_ip, s.country, s.is_member,
    s.requirements::text AS requirements, s.improve_consent, s.consent_at, l.uuid AS crm_lead_uuid,
    c.uuid AS cart_uuid, q.uuid AS quote_uuid, q.quote_number, o.uuid AS order_uuid, o.order_number
]]

function ShopChatQueries.adminList(ns_id, params)
    params = params or {}
    local limit = U.clamp(U.int(params.limit, 25), 1, 200)
    local offset = math.max(0, U.int(params.offset, 0))
    local where, vals = { "s.namespace_id = ?" }, { ns_id }
    if U.nz(params.q) then
        where[#where + 1] = "(s.email ILIKE ? OR s.contact_phone ILIKE ? OR s.messages::text ILIKE ?)"
        local like = "%" .. tostring(params.q):gsub("[%%_\\]", "\\%0") .. "%"
        vals[#vals + 1] = like
        vals[#vals + 1] = like
        vals[#vals + 1] = like
    end
    if U.bool(params.with_messages_only, false) then where[#where + 1] = "s.message_count > 0" end
    -- ?consent=true: only chats the customer agreed we may use to improve advice
    if U.bool(params.consent, false) then where[#where + 1] = "s.improve_consent" end
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
          LEFT JOIN crm_leads l ON l.id = s.crm_lead_id
         WHERE ]] .. table.concat(where, " AND ") .. " ORDER BY s.updated_at DESC, s.id DESC LIMIT ? OFFSET ?",
        unpack(vals))
    local total = rows[1] and tonumber(rows[1].total) or 0
    for _, r in ipairs(rows) do
        r.total = nil
        if r.first_user_message then r.first_user_message = r.first_user_message:sub(1, 200) end
        r.requirements = U.dec(r.requirements, {})
        r.improve_consent = r.improve_consent == true
        r.is_member = r.is_member == true
        for _, k in ipairs({ "email", "summary", "cart_uuid", "quote_uuid", "quote_number", "order_uuid",
                             "order_number", "first_user_message", "consent_at", "crm_lead_uuid",
                             "contact_name", "contact_phone", "client_ip", "country" }) do
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
          LEFT JOIN crm_leads l ON l.id = s.crm_lead_id
         WHERE s.namespace_id = ? AND s.uuid = ?]], ns_id, uuid)[1]
    if not r then return nil end
    r.messages = U.arr(U.dec(r.messages, {}))
    r.requirements = U.dec(r.requirements, {})
    r.improve_consent = r.improve_consent == true
    r.is_member = r.is_member == true
    for _, k in ipairs({ "email", "summary", "cart_uuid", "quote_uuid", "quote_number", "order_uuid", "order_number",
                         "consent_at", "crm_lead_uuid", "contact_name", "contact_phone", "client_ip", "country" }) do
        if r[k] == nil then r[k] = U.null end
    end
    return r
end

return ShopChatQueries
