-- Email connectors for the legal chaser (SPEC §3.5): IMAP, Gmail API, Microsoft
-- 365 (Graph). A connector only READS a mailbox. What it fetches is stored as
-- data (property_deals_inbound_messages) and matched to a deal by rules:
--   1. the deal reference we put in every outbound subject, "[PD-1a2b3c4d]"
--   2. else the sender is a party (contact / firm email) on exactly one active deal
--   3. else the sender is exactly one lead: the reply is scored and a hot one raises a "call now" alert
-- A match marks the last chase to that party as replied (rules, not AI), updates
-- the deal's health, and starts the legal chaser on the deal's chase task when
-- the workspace has an AI provider. Text is never treated as instructions.
--
--   config (non-secret)                              secret (sealed, AES-256-GCM)
--   imap  { host, port=993, ssl=true, username, mailbox="INBOX" }   password
--   gmail { client_id, token_url?, api_base? }                     JSON { client_secret, refresh_token }
--   m365  { tenant_id, client_id, mailbox, token_url?, api_base? } client secret
local cjson = require("cjson")
local db = require("lapis.db")
local U = require("property_deals.util")
local Box = require("helper.secret-box")

local M = {}

local PURPOSE = "property_deals_mail"
local MAX_PER_SYNC = 25

local function null(v) return v == nil or v == db.NULL end

-- ---------------------------------------------------------------------------
-- Connector records
-- ---------------------------------------------------------------------------

function M.present(row)
    if not row then return nil end
    local out = {}
    for k, v in pairs(row) do
        if k ~= "secret_sealed" and k ~= "id" and k ~= "namespace_id" and not null(v) then out[k] = v end
    end
    out.config, out.cursor = U.json(row.config), U.json(row.cursor)
    out.has_secret = not null(row.secret_sealed)
    return out
end

function M.get(ns, id)
    if not U.is_uuid(id) then return nil end
    return U.one("SELECT * FROM property_deals_mail_connectors WHERE namespace_id = ? AND uuid = ?", ns, id)
end

local REQUIRED = { imap = { "host", "username" }, gmail = { "client_id" }, m365 = { "tenant_id", "client_id", "mailbox" } }

function M.save(ns, b, existing)
    local errors, row = {}, {}
    local kind = b.kind or (existing and existing.kind)
    if not REQUIRED[kind or ""] then errors.kind = "imap, gmail or m365" end
    if not existing or b.name ~= nil then
        if type(b.name) ~= "string" or b.name == "" then errors.name = "required" else row.name = b.name:sub(1, 120) end
    end
    if b.kind ~= nil then row.kind = b.kind end
    local config = b.config ~= nil and b.config or (existing and U.json(existing.config)) or {}
    if type(config) ~= "table" then errors.config = "object" config = {} end
    for _, f in ipairs(REQUIRED[kind or ""] or {}) do
        if type(config[f]) ~= "string" or config[f] == "" then errors["config." .. f] = "required" end
    end
    local Providers = require("lib.ai-providers")
    for _, f in ipairs({ "token_url", "api_base" }) do
        if config[f] ~= nil then
            local ok, err = Providers.url_ok(config[f])
            if not ok then errors["config." .. f] = err end
        end
    end
    if b.config ~= nil then row.config = cjson.encode(config) end
    if b.secret ~= nil then
        if type(b.secret) == "table" then b.secret = cjson.encode(b.secret) end
        if b.secret == "" then row.secret_sealed, row.secret_hint = db.NULL, db.NULL
        elseif type(b.secret) ~= "string" then errors.secret = "string (or object for gmail)"
        else row.secret_sealed, row.secret_hint = Box.seal(b.secret, PURPOSE), "set" end
    end
    if b.enabled ~= nil then row.enabled = b.enabled ~= false end
    if next(errors) then return nil, errors end
    row.updated_at = db.raw("NOW()")
    if existing then
        db.update("property_deals_mail_connectors", row, { id = existing.id })
        return M.get(ns, existing.uuid)
    end
    row.namespace_id = ns
    return db.insert("property_deals_mail_connectors", row, { returning = "*" })[1]
end

-- ---------------------------------------------------------------------------
-- MIME (just enough to get readable text out of a message)
-- ---------------------------------------------------------------------------

local function header(headers, name)
    local v = headers:match("\n" .. name .. ":%s*(.-)\r?\n%S") or headers:match("^" .. name .. ":%s*(.-)\r?\n%S")
        or headers:match("\n" .. name .. ":%s*(.-)%s*$")
    if v then v = v:gsub("\r?\n%s+", " ") end
    return v
end

local function headers_ci(raw)
    -- Case-insensitive lookups: normalise header names to Title-case.
    return "\n" .. raw:gsub("\r\n", "\n"):gsub("\n([%w%-]+):", function(n)
        return "\n" .. n:lower():gsub("^%l", string.upper):gsub("%-%l", string.upper) .. ":"
    end) .. "\nX-End: 1\n"
end

local function qp_decode(s)
    s = s:gsub("=\r?\n", "")
    return (s:gsub("=(%x%x)", function(h) return string.char(tonumber(h, 16)) end))
end

local function decode_part(body, encoding)
    encoding = (encoding or ""):lower()
    if encoding:find("base64", 1, true) then return ngx.decode_base64((body:gsub("%s", ""))) or body end
    if encoding:find("quoted%-printable") then return qp_decode(body) end
    return body
end

local function strip_html(s)
    s = s:gsub("<[Ss][Tt][Yy][Ll][Ee].-</[Ss][Tt][Yy][Ll][Ee]>", ""):gsub("<[Bb][Rr]%s*/?>", "\n")
        :gsub("</[Pp]>", "\n"):gsub("<[^>]+>", ""):gsub("&nbsp;", " "):gsub("&amp;", "&"):gsub("&lt;", "<"):gsub("&gt;", ">")
    return s
end

--- Text of a MIME body given its Content-Type / Content-Transfer-Encoding.
function M.mime_text(content_type, encoding, body, depth)
    depth = depth or 0
    content_type = content_type or "text/plain"
    local boundary = content_type:match('boundary="([^"]+)"') or content_type:match("boundary=([^;%s]+)")
    if boundary and depth < 4 then
        local html
        local delim, parts, pos = "--" .. boundary, {}, 1
        while true do
            local _, e = body:find(delim, pos, true)
            if not e then break end
            local nxt = body:find(delim, e + 1, true)
            if not nxt or body:sub(e + 1, e + 2) == "--" then break end
            parts[#parts + 1] = (body:sub(e + 1, nxt - 1):gsub("^\r?\n", ""):gsub("\r?\n$", ""))
            pos = nxt
        end
        for _, part in ipairs(parts) do
            local h, b = part:match("^(.-)\r?\n\r?\n(.*)$")
            if h then
                local hs = headers_ci(h)
                local ct = header(hs, "Content%-Type") or "text/plain"
                local te = header(hs, "Content%-Transfer%-Encoding")
                if ct:lower():find("multipart/", 1, true) then
                    local t = M.mime_text(ct, te, b, depth + 1)
                    if t and t ~= "" then return t end
                elseif ct:lower():find("text/plain", 1, true) then
                    return decode_part(b, te)
                elseif ct:lower():find("text/html", 1, true) then
                    html = html or strip_html(decode_part(b, te))
                end
            end
        end
        return html or ""
    end
    local text = decode_part(body, encoding)
    if content_type:lower():find("text/html", 1, true) then text = strip_html(text) end
    return text
end

local function address(s)
    if not s then return nil, nil end
    local name, addr = s:match('^%s*"?([^"<]-)"?%s*<([^>]+)>')
    if addr then return addr:lower(), name ~= "" and name or nil end
    addr = s:match("([%w%._%%%+%-]+@[%w%.%-]+)")
    return addr and addr:lower() or nil, nil
end

-- ---------------------------------------------------------------------------
-- IMAP (read-only: EXAMINE, UID SEARCH, UID FETCH with BODY.PEEK)
-- ---------------------------------------------------------------------------

local function imap_quote(s)
    return '"' .. tostring(s):gsub('[\\"]', "\\%0") .. '"'
end

local Imap = {}
Imap.__index = Imap

function Imap.connect(cfg, password)
    local sock = ngx.socket.tcp()
    sock:settimeout(15000)
    local Providers = require("lib.ai-providers")
    local okurl, uerr = Providers.url_ok("https://" .. cfg.host)
    if not okurl then return nil, "IMAP host: " .. uerr end
    local port = tonumber(cfg.port) or 993
    local ok, err = sock:connect(cfg.host, port)
    if not ok then return nil, "IMAP connect: " .. tostring(err) end
    if cfg.ssl ~= false then
        local verify = os.getenv("PROPERTY_DEALS_IMAP_TLS_VERIFY") ~= "false"
        local sok, serr = sock:sslhandshake(nil, cfg.host, verify)
        if not sok then return nil, "IMAP TLS: " .. tostring(serr) end
    end
    local self = setmetatable({ sock = sock, n = 0 }, Imap)
    local greeting, gerr = sock:receive("*l")
    if not greeting then return nil, "IMAP greeting: " .. tostring(gerr) end
    local res, lerr = self:cmd("LOGIN " .. imap_quote(cfg.username) .. " " .. imap_quote(password or ""))
    if not res then sock:close(); return nil, "IMAP login failed: " .. tostring(lerr) end
    return self
end

--- Send a command; returns { lines = {...}, literals = {...} } or nil, err.
function Imap:cmd(command)
    self.n = self.n + 1
    local tag = "A" .. self.n
    local ok, err = self.sock:send(tag .. " " .. command .. "\r\n")
    if not ok then return nil, err end
    local out = { lines = {}, literals = {} }
    while true do
        local line, rerr = self.sock:receive("*l")
        if not line then return nil, rerr end
        local size = tonumber(line:match("{(%d+)}$"))
        if size then
            local lit, lerr = self.sock:receive(size)
            if not lit then return nil, lerr end
            out.literals[#out.literals + 1] = lit
        end
        if line:sub(1, #tag + 1) == tag .. " " then
            if line:match("^" .. tag .. " OK") then return out end
            return nil, line:sub(#tag + 2)
        end
        out.lines[#out.lines + 1] = line
    end
end

function Imap:close()
    pcall(function() self:cmd("LOGOUT") end)
    self.sock:close()
end

local function fetch_imap(conn, secret, cursor)
    local cfg = U.json(conn.config) or {}
    local c, err = Imap.connect(cfg, secret)
    if not c then return nil, err end
    local function done(...) c:close(); return ... end
    local sel, serr = c:cmd("EXAMINE " .. imap_quote(cfg.mailbox or "INBOX"))
    if not sel then return done(nil, "IMAP mailbox: " .. tostring(serr)) end
    local last = tonumber(cursor.last_uid) or 0
    local search = last > 0 and ("UID SEARCH UID " .. (last + 1) .. ":*")
        or ("UID SEARCH SINCE " .. os.date("!%d-%b-%Y", ngx.time() - 7 * 86400))
    local found, ferr = c:cmd(search)
    if not found then return done(nil, "IMAP search: " .. tostring(ferr)) end
    local uids = {}
    for _, l in ipairs(found.lines) do
        local list = l:match("^%* SEARCH(.*)$")
        if list then for u in list:gmatch("%d+") do if tonumber(u) > last then uids[#uids + 1] = tonumber(u) end end end
    end
    table.sort(uids)
    local msgs = {}
    for i, uid in ipairs(uids) do
        if i > MAX_PER_SYNC then break end
        local r = c:cmd("UID FETCH " .. uid .. " (UID BODY.PEEK[HEADER.FIELDS (FROM TO SUBJECT DATE MESSAGE-ID CONTENT-TYPE "
            .. "CONTENT-TRANSFER-ENCODING)] BODY.PEEK[TEXT]<0.60000>)")
        if r and #r.literals >= 1 then
            local hs = headers_ci(r.literals[1])
            local from, from_name = address(header(hs, "From"))
            msgs[#msgs + 1] = {
                external_id = "imap:" .. (header(hs, "Message%-Id") or (cfg.host .. ":" .. uid)),
                from_address = from, from_name = from_name, to_address = header(hs, "To"), subject = header(hs, "Subject"),
                received_at = header(hs, "Date"),
                body_text = M.mime_text(header(hs, "Content%-Type"), header(hs, "Content%-Transfer%-Encoding"), r.literals[2] or ""),
            }
        end
        last = math.max(last, uid)
    end
    return done(msgs, nil, { last_uid = last })
end

-- ---------------------------------------------------------------------------
-- OAuth providers (Gmail, Microsoft Graph)
-- ---------------------------------------------------------------------------

local function http_json(url, opts)
    local ok, err = require("lib.ai-providers").url_ok(url)
    if not ok then return nil, err end
    local httpc = require("resty.http").new()
    httpc:set_timeout(20000)
    local res, rerr = httpc:request_uri(url, { method = opts.method or "GET", headers = opts.headers, body = opts.body,
        ssl_verify = os.getenv("PROPERTY_DEALS_MAIL_TLS_VERIFY") ~= "false" })
    if not res then return nil, tostring(rerr) end
    local data = require("cjson.safe").decode(res.body or "")
    if res.status >= 300 then
        return nil, "HTTP " .. res.status .. ": " .. tostring(type(data) == "table" and (data.error_description
            or (type(data.error) == "table" and data.error.message) or data.error) or res.body):sub(1, 200)
    end
    return data or {}
end

local function form(t)
    local out = {}
    for k, v in pairs(t) do out[#out + 1] = ngx.escape_uri(k) .. "=" .. ngx.escape_uri(tostring(v)) end
    return table.concat(out, "&")
end

local function b64url(s)
    if type(s) ~= "string" then return "" end
    s = s:gsub("-", "+"):gsub("_", "/")
    local pad = #s % 4
    if pad > 0 then s = s .. string.rep("=", 4 - pad) end
    return ngx.decode_base64(s) or ""
end

local function gmail_text(part)
    if type(part) ~= "table" then return nil end
    local mime = tostring(part.mimeType or "")
    if mime == "text/plain" and part.body and part.body.data then return b64url(part.body.data) end
    for _, p in ipairs(part.parts or {}) do
        local t = gmail_text(p)
        if t then return t end
    end
    if mime == "text/html" and part.body and part.body.data then return strip_html(b64url(part.body.data)) end
    return nil
end

local function fetch_gmail(conn, secret, cursor)
    local cfg = U.json(conn.config) or {}
    local s = require("cjson.safe").decode(secret or "") or {}
    local tok, err = http_json(cfg.token_url or "https://oauth2.googleapis.com/token", { method = "POST",
        headers = { ["Content-Type"] = "application/x-www-form-urlencoded" },
        body = form({ grant_type = "refresh_token", client_id = cfg.client_id, client_secret = s.client_secret or "",
            refresh_token = s.refresh_token or "" }) })
    if not tok or not tok.access_token then return nil, "Gmail sign-in: " .. tostring(err or "no access token") end
    local api = (cfg.api_base or "https://gmail.googleapis.com"):gsub("/+$", "")
    local auth = { Authorization = "Bearer " .. tok.access_token }
    local after = tonumber(cursor.after) or (ngx.time() - 7 * 86400)
    local list, lerr = http_json(api .. "/gmail/v1/users/me/messages?maxResults=" .. MAX_PER_SYNC .. "&q="
        .. ngx.escape_uri("in:inbox after:" .. after), { headers = auth })
    if not list then return nil, "Gmail list: " .. tostring(lerr) end
    local msgs, newest = {}, after
    for _, m in ipairs(list.messages or {}) do
        local full = http_json(api .. "/gmail/v1/users/me/messages/" .. ngx.escape_uri(m.id) .. "?format=full", { headers = auth })
        if full then
            local h = {}
            for _, x in ipairs(full.payload and full.payload.headers or {}) do h[tostring(x.name):lower()] = x.value end
            local from, from_name = address(h.from)
            local ms = tonumber(full.internalDate)
            if ms then newest = math.max(newest, math.floor(ms / 1000)) end
            msgs[#msgs + 1] = { external_id = "gmail:" .. m.id, from_address = from, from_name = from_name, to_address = h.to,
                subject = h.subject, received_at = ms and os.date("!%Y-%m-%dT%H:%M:%SZ", math.floor(ms / 1000)) or h.date,
                body_text = gmail_text(full.payload) or full.snippet or "" }
        end
    end
    return msgs, nil, { after = newest }
end

local function fetch_m365(conn, secret, cursor)
    local cfg = U.json(conn.config) or {}
    local tok, err = http_json(cfg.token_url or ("https://login.microsoftonline.com/" .. ngx.escape_uri(cfg.tenant_id)
        .. "/oauth2/v2.0/token"), { method = "POST", headers = { ["Content-Type"] = "application/x-www-form-urlencoded" },
        body = form({ grant_type = "client_credentials", client_id = cfg.client_id, client_secret = secret or "",
            scope = "https://graph.microsoft.com/.default" }) })
    if not tok or not tok.access_token then return nil, "Microsoft 365 sign-in: " .. tostring(err or "no access token") end
    local api = (cfg.api_base or "https://graph.microsoft.com"):gsub("/+$", "")
    local since = cursor.since or os.date("!%Y-%m-%dT%H:%M:%SZ", ngx.time() - 7 * 86400)
    local url = api .. "/v1.0/users/" .. ngx.escape_uri(cfg.mailbox) .. "/mailFolders/inbox/messages?$top=" .. MAX_PER_SYNC
        .. "&$orderby=receivedDateTime&$filter=" .. ngx.escape_uri("receivedDateTime gt " .. since)
        .. "&$select=id,internetMessageId,subject,from,toRecipients,receivedDateTime,body"
    local list, lerr = http_json(url, { headers = { Authorization = "Bearer " .. tok.access_token,
        Prefer = 'outlook.body-content-type="text"' } })
    if not list then return nil, "Microsoft 365 list: " .. tostring(lerr) end
    local msgs, newest = {}, since
    for _, m in ipairs(list.value or {}) do
        local f = type(m.from) == "table" and m.from.emailAddress or {}
        local to = {}
        for _, r in ipairs(m.toRecipients or {}) do to[#to + 1] = r.emailAddress and r.emailAddress.address end
        if m.receivedDateTime and m.receivedDateTime > newest then newest = m.receivedDateTime end
        local body = type(m.body) == "table" and m.body or {}
        msgs[#msgs + 1] = { external_id = "m365:" .. tostring(m.internetMessageId or m.id),
            from_address = f.address and f.address:lower(), from_name = f.name, to_address = table.concat(to, ", "),
            subject = m.subject, received_at = m.receivedDateTime,
            body_text = body.contentType == "html" and strip_html(body.content or "") or (body.content or "") }
    end
    return msgs, nil, { since = newest }
end

local FETCH = { imap = fetch_imap, gmail = fetch_gmail, m365 = fetch_m365 }

-- ---------------------------------------------------------------------------
-- Ingest: store, match to a deal, mark replies, start the legal chaser
-- ---------------------------------------------------------------------------

local function match_deal(ns, m)
    local ref = m.subject and m.subject:match("%[PD%-(%x%x%x%x%x%x%x%x)%]")
    if ref then
        local d = U.one("SELECT uuid FROM property_deals_deals WHERE namespace_id = ? AND uuid::text LIKE ? LIMIT 2",
            ns, ref:lower() .. "%")
        if d then return d.uuid, "reference" end
    end
    if m.from_address then
        local rows = db.query([[
            SELECT DISTINCT p.deal_uuid FROM property_deals_deal_parties p
            JOIN property_deals_deals dl ON dl.uuid = p.deal_uuid AND dl.status = 'active'
            LEFT JOIN crm_contacts c ON c.uuid = p.contact_uuid LEFT JOIN crm_accounts a ON a.uuid = p.account_uuid
            WHERE p.namespace_id = ? AND (LOWER(c.email) = ? OR LOWER(a.email) = ?) LIMIT 2
        ]], ns, m.from_address, m.from_address)
        if #rows == 1 then return rows[1].deal_uuid, "sender" end
    end
    return nil, nil
end

--- A reply from a lead (not on a deal): the sender's address is exactly one lead's email.
local function match_lead(ns, m)
    if not m.from_address then return nil end
    local rows = db.query([[
        SELECT uuid FROM crm_leads WHERE namespace_id = ? AND LOWER(email) = ? AND deleted_at IS NULL
        ORDER BY updated_at DESC LIMIT 2
    ]], ns, m.from_address)
    return #rows == 1 and rows[1].uuid or nil
end

local function received(v)
    if type(v) ~= "string" or v == "" then return db.raw("NOW()") end
    -- RFC 2822 dates parse in Postgres once the weekday and zone name are trimmed.
    local ok, r = pcall(U.one, "SELECT ?::timestamptz AS t", (v:gsub("^%a%a%a,%s*", ""):gsub("%s*%(.-%)%s*$", "")))
    return ok and r and r.t or db.raw("NOW()")
end

function M.ingest(ns, conn, m)
    local deal_uuid, matched_by = match_deal(ns, m)
    local lead_uuid = not deal_uuid and match_lead(ns, m) or nil
    if lead_uuid then matched_by = "lead" end
    local row = db.query([[
        INSERT INTO property_deals_inbound_messages (namespace_id, connector_uuid, external_id, from_address, from_name,
            to_address, subject, received_at, body_text, deal_uuid, matched_by, lead_uuid)
        VALUES (?, ?, ?, ?, ?, ?, ?, ?::timestamptz, ?, ?, ?, ?)
        ON CONFLICT (namespace_id, external_id) DO NOTHING RETURNING *
    ]], ns, conn and conn.uuid or db.NULL, tostring(m.external_id):sub(1, 255), m.from_address or db.NULL,
        m.from_name or db.NULL, m.to_address or db.NULL, m.subject or db.NULL, received(m.received_at),
        tostring(m.body_text or ""):sub(1, 60000), deal_uuid or db.NULL, matched_by or db.NULL, lead_uuid or db.NULL)[1]
    if not row then return nil end
    if deal_uuid then
        -- The last unanswered chase to this sender (or this deal, for a reference match) now has its reply.
        local chase = U.one([[
            UPDATE property_deals_chases SET status = 'replied', reply_at = ?::timestamptz, reply_summary = LEFT(?, 500),
                updated_at = NOW()
            WHERE id = (SELECT id FROM property_deals_chases WHERE namespace_id = ? AND deal_uuid = ? AND status = 'sent'
                        AND (LOWER(to_address) = ? OR ? = 'reference') ORDER BY sent_at DESC NULLS LAST LIMIT 1)
            RETURNING uuid
        ]], row.received_at, row.subject or "", ns, deal_uuid, m.from_address or "", matched_by)
        if chase then db.update("property_deals_inbound_messages", { chase_uuid = chase.uuid }, { id = row.id }) end
        local settings = require("helper.plugin-sdk").settings("property_deals", ns)
        pcall(require("property_deals.health").recompute_deal, ns, deal_uuid, settings)
        -- Let the legal chaser read it and redraft, if it's set up.
        local task = U.one([[
            SELECT task_uuid FROM property_deals_task_details
            WHERE namespace_id = ? AND deal_uuid = ? AND agent_eligible AND agent_key = 'legal_chaser'
              AND pd_status IN ('todo', 'in_progress', 'waiting_third_party') ORDER BY urgency_score DESC LIMIT 1
        ]], ns, deal_uuid)
        if task then
            local Config = require("property_deals.ai.config")
            local cfg = Config.agent(ns, "legal_chaser")
            if cfg.enabled and (cfg.route == "jobshout" or #Config.route(ns, "draft").chain > 0) then
                local run = require("property_deals.ai.runner").start(ns, task.task_uuid, { trigger = "email" })
                if run then db.update("property_deals_inbound_messages", { agent_run_uuid = run.uuid }, { id = row.id }) end
            end
        end
    end
    if lead_uuid then
        -- Score the reply; a hot one raises a "call now" task and alerts (property_deals.replies).
        local ok, err = pcall(require("property_deals.replies").handle, ns, row)
        if not ok then ngx.log(ngx.WARN, "[property_deals] reply scoring: ", tostring(err)) end
    end
    db.update("property_deals_inbound_messages", { processed_at = db.raw("NOW()") }, { id = row.id })
    return row
end

--- Fetch new mail for one connector. @return { fetched, stored, matched } | nil, err
function M.sync(ns, conn)
    local secret = not null(conn.secret_sealed) and Box.open(conn.secret_sealed, PURPOSE) or nil
    local fetch = FETCH[conn.kind]
    local ok, msgs, err, cursor = pcall(fetch, conn, secret, U.json(conn.cursor) or {})
    if not ok then msgs, err = nil, msgs end
    if not msgs then
        db.update("property_deals_mail_connectors", { last_error = tostring(err):sub(1, 500), updated_at = db.raw("NOW()") },
            { id = conn.id })
        return nil, tostring(err)
    end
    local stored, matched = 0, 0
    for _, m in ipairs(msgs) do
        local r = M.ingest(ns, conn, m)
        if r then
            stored = stored + 1
            if not null(r.deal_uuid) then matched = matched + 1 end
        end
    end
    local merged = U.json(conn.cursor) or {}
    for k, v in pairs(cursor or {}) do merged[k] = v end
    db.update("property_deals_mail_connectors", { cursor = cjson.encode(merged), last_synced_at = db.raw("NOW()"),
        last_error = db.NULL, updated_at = db.raw("NOW()") }, { id = conn.id })
    return { fetched = #msgs, stored = stored, matched = matched }
end

function M.sync_all(ns)
    local out = { connectors = 0, stored = 0, errors = 0 }
    for _, c in ipairs(db.query("SELECT * FROM property_deals_mail_connectors WHERE namespace_id = ? AND enabled", ns)) do
        out.connectors = out.connectors + 1
        local r = M.sync(ns, c)
        if r then out.stored = out.stored + r.stored else out.errors = out.errors + 1 end
    end
    return out
end

return M
