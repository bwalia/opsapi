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
-- Each run reads up to MAX_PER_RUN messages per mailbox, oldest first, within a time budget; the
-- cursor only moves past what was processed, so a busy inbox catches up over the next runs. One
-- message that can't be stored is logged, kept as a row with matched_by "error" and skipped: it
-- never blocks the mailbox. Errors shown to people (and last_error) are short and generic; what a
-- server said goes to the log.
local cjson = require("cjson")
local db = require("lapis.db")
local U = require("property_deals.util")
local Box = require("helper.secret-box")

local M = {}

local PURPOSE = "property_deals_mail"
local MAX_PER_RUN = 100       -- messages per mailbox per run; the next run carries on
local GMAIL_LIST_PAGES = 50   -- 500 ids a page

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
    if kind == "imap" then
        for _, f in ipairs({ "host", "username", "mailbox" }) do
            if type(config[f]) == "string" and config[f]:find("[%z\r\n]") then
                errors["config." .. f] = "no line breaks"
            end
        end
        if type(config.host) == "string" and not config.host:match("^[%w%-%.]+$") then
            errors["config.host"] = "a host name, e.g. imap.example.com"
        end
        if config.ssl == false and os.getenv("OPSAPI_MAIL_ALLOW_PRIVATE") ~= "true" then
            errors["config.ssl"] = "IMAP without TLS sends the password in clear; use ssl (port 993)"
        end
        if type(b.secret) == "string" and b.secret:find("[%z\r\n]") then errors.secret = "no line breaks" end
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

local function charset(content_type)
    return content_type and content_type:match('[Cc][Hh][Aa][Rr][Ss][Ee][Tt]="?([^";%s]+)')
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
                    return U.utf8(decode_part(b, te), charset(ct))
                elseif ct:lower():find("text/html", 1, true) then
                    html = html or strip_html(U.utf8(decode_part(b, te), charset(ct)))
                end
            end
        end
        return html or ""
    end
    local text = U.utf8(decode_part(body, encoding), charset(content_type))
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

--- Did the receiving server check the sender (DMARC pass in Authentication-Results)?
local function dmarc_pass(v)
    return type(v) == "string" and v:lower():find("dmarc=pass", 1, true) ~= nil
end

local function out_of_time(deadline)
    ngx.update_time()
    return ngx.now() >= deadline
end

--- Which of these external ids (prefix .. id) are stored already: { [id] = true }.
local function known_ids(ns, prefix, ids)
    local known = {}
    for i = 1, #ids, 500 do
        local lits = {}
        for j = i, math.min(i + 499, #ids) do lits[#lits + 1] = db.escape_literal(prefix .. ids[j]) end
        for _, r in ipairs(db.query("SELECT external_id FROM property_deals_inbound_messages WHERE namespace_id = ? "
            .. "AND external_id IN (" .. table.concat(lits, ",") .. ")", ns)) do
            known[r.external_id:sub(#prefix + 1)] = true
        end
    end
    return known
end

-- ---------------------------------------------------------------------------
-- IMAP (read-only: EXAMINE, UID SEARCH, UID FETCH with BODY.PEEK)
-- ---------------------------------------------------------------------------

local function imap_quote(s)
    return '"' .. tostring(s):gsub('[\\"]', "\\%0") .. '"'
end

local Imap = {}
Imap.__index = Imap

--- @return Imap | nil, public error, raw error
function Imap.connect(cfg, password)
    local host, port = tostring(cfg.host or ""), tonumber(cfg.port) or 993
    if not host:match("^[%w%-%.]+$") then return nil, "IMAP host must be a host name" end
    -- A line break would end the LOGIN command and start another one.
    if tostring(cfg.username or ""):find("[%z\r\n]") or tostring(password or ""):find("[%z\r\n]") then
        return nil, "IMAP username or password contains a line break"
    end
    if cfg.ssl == false and os.getenv("OPSAPI_MAIL_ALLOW_PRIVATE") ~= "true" then
        return nil, "IMAP without TLS sends the password in clear; turn ssl on"
    end
    -- Resolve once, check, and connect to the address that was checked (no DNS rebinding).
    local Webhooks = require("lib.outbound-webhooks")
    local ips, rerr = Webhooks.resolve(host)
    if not ips then return nil, "IMAP host not found", rerr end
    if os.getenv("OPSAPI_AI_ALLOW_PRIVATE") ~= "true" then
        local named_private = host == "localhost" or host:match("%.local$") or host:match("%.internal$")
            or host:match("%.svc$") or not host:find(".", 1, true)
        for _, ip in ipairs(ips) do
            if named_private or not Webhooks.isPublicIPv4(ip) then return nil, "IMAP host must be a public server" end
        end
    end
    local sock = ngx.socket.tcp()
    sock:settimeout(15000)
    local ok, err = sock:connect(ips[1], port)
    if not ok then return nil, "could not connect to the IMAP server", err end
    if cfg.ssl ~= false then
        -- SNI and the certificate check use the name, not the address.
        local verify = os.getenv("PROPERTY_DEALS_IMAP_TLS_VERIFY") ~= "false"
        local sok, serr = sock:sslhandshake(nil, host, verify)
        if not sok then sock:close(); return nil, "IMAP TLS handshake failed", serr end
    end
    local self = setmetatable({ sock = sock, n = 0 }, Imap)
    local greeting, gerr = sock:receive("*l")
    if not greeting then sock:close(); return nil, "the IMAP server didn't answer", gerr end
    local res, lerr = self:cmd("LOGIN " .. imap_quote(cfg.username) .. " " .. imap_quote(password or ""))
    if not res then sock:close(); return nil, "IMAP sign-in failed", lerr end
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

-- Fetchers return messages oldest first, each with the cursor to save once it is processed:
--   msgs | nil, public error, raw error     (msgs with an error: fetching stopped part way)
local function fetch_imap(conn, secret, cursor, deadline)
    local cfg = U.json(conn.config) or {}
    local c, err, raw = Imap.connect(cfg, secret)
    if not c then return nil, err, raw end
    local function done(...) c:close(); return ... end
    local mailbox = tostring(cfg.mailbox or "INBOX")
    if mailbox:find("[%z\r\n]") then return done(nil, "IMAP mailbox name contains a line break") end
    local sel, serr = c:cmd("EXAMINE " .. imap_quote(mailbox))
    if not sel then return done(nil, "IMAP mailbox not found", serr) end
    local last = tonumber(cursor.last_uid) or 0
    local search = last > 0 and ("UID SEARCH UID " .. (last + 1) .. ":*")
        or ("UID SEARCH SINCE " .. os.date("!%d-%b-%Y", ngx.time() - 7 * 86400))
    local found, ferr = c:cmd(search)
    if not found then return done(nil, "IMAP search failed", ferr) end
    local uids = {}
    for _, l in ipairs(found.lines) do
        local list = l:match("^%* SEARCH(.*)$")
        if list then for u in list:gmatch("%d+") do if tonumber(u) > last then uids[#uids + 1] = tonumber(u) end end end
    end
    table.sort(uids)
    local msgs, fetched = {}, 0
    for _, uid in ipairs(uids) do
        if fetched >= MAX_PER_RUN or out_of_time(deadline) then break end
        local r, rerr = c:cmd("UID FETCH " .. uid .. " (UID BODY.PEEK[HEADER.FIELDS (FROM TO SUBJECT DATE MESSAGE-ID "
            .. "CONTENT-TYPE CONTENT-TRANSFER-ENCODING AUTHENTICATION-RESULTS)] BODY.PEEK[TEXT]<0.60000>)")
        -- The connection broke: stop here, the cursor stays on the last message read.
        if not r then return done(msgs, "IMAP fetch failed", rerr) end
        fetched = fetched + 1
        if #r.literals >= 1 then
            local hs = headers_ci(r.literals[1])
            local from, from_name = address(header(hs, "From"))
            msgs[#msgs + 1] = {
                external_id = "imap:" .. (header(hs, "Message%-Id") or (cfg.host .. ":" .. uid)),
                from_address = from, from_name = from_name, to_address = header(hs, "To"),
                subject = header(hs, "Subject"), received_at = header(hs, "Date"),
                sender_verified = dmarc_pass(header(hs, "Authentication%-Results")),
                body_text = M.mime_text(header(hs, "Content%-Type"), header(hs, "Content%-Transfer%-Encoding"),
                    r.literals[2] or ""),
                cursor = { last_uid = uid },
            }
        else
            msgs[#msgs + 1] = { skip = true, cursor = { last_uid = uid } } -- expunged meanwhile: nothing to read
        end
    end
    return done(msgs)
end

-- ---------------------------------------------------------------------------
-- OAuth providers (Gmail, Microsoft Graph)
-- ---------------------------------------------------------------------------

local function http_json(url, opts)
    return require("property_deals.http").json(url, { method = opts.method, headers = opts.headers, body = opts.body,
        ssl_verify = os.getenv("PROPERTY_DEALS_MAIL_TLS_VERIFY") ~= "false" })
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
    local mime, cs = tostring(part.mimeType or ""), nil
    for _, h in ipairs(type(part.headers) == "table" and part.headers or {}) do
        if tostring(h.name):lower() == "content-type" then cs = charset(h.value) end
    end
    if mime == "text/plain" and part.body and part.body.data then return U.utf8(b64url(part.body.data), cs) end
    for _, p in ipairs(part.parts or {}) do
        local t = gmail_text(p)
        if t then return t end
    end
    if mime == "text/html" and part.body and part.body.data then
        return strip_html(U.utf8(b64url(part.body.data), cs))
    end
    return nil
end

local function fetch_gmail(conn, secret, cursor, deadline, ns)
    local cfg = U.json(conn.config) or {}
    local s = require("cjson.safe").decode(secret or "") or {}
    local tok, err = http_json(cfg.token_url or "https://oauth2.googleapis.com/token", { method = "POST",
        headers = { ["Content-Type"] = "application/x-www-form-urlencoded" },
        body = form({ grant_type = "refresh_token", client_id = cfg.client_id, client_secret = s.client_secret or "",
            refresh_token = s.refresh_token or "" }) })
    if not tok or not tok.access_token then return nil, "Gmail sign-in failed", err or "no access token" end
    local api = (cfg.api_base or "https://gmail.googleapis.com"):gsub("/+$", "")
    local auth = { Authorization = "Bearer " .. tok.access_token }
    local after = tonumber(cursor.after) or (ngx.time() - 7 * 86400)
    -- Gmail lists newest first: page through the ids, then read the oldest first.
    local ids, page, pages = {}, nil, 0
    repeat
        local list, lerr = http_json(api .. "/gmail/v1/users/me/messages?maxResults=500&q="
            .. ngx.escape_uri("in:inbox after:" .. after) .. (page and ("&pageToken=" .. ngx.escape_uri(page)) or ""),
            { headers = auth })
        if not list then return nil, "Gmail: couldn't list messages", lerr end
        for _, m in ipairs(type(list.messages) == "table" and list.messages or {}) do ids[#ids + 1] = tostring(m.id) end
        page, pages = list.nextPageToken, pages + 1
    until not page or pages >= GMAIL_LIST_PAGES
    -- The cursor overlaps by a second, so skip what's stored already.
    local known = known_ids(ns, "gmail:", ids)
    local msgs = {}
    for i = #ids, 1, -1 do
        local id = ids[i]
        if not known[id] then
            if #msgs >= MAX_PER_RUN or out_of_time(deadline) then break end
            local full, ferr = http_json(api .. "/gmail/v1/users/me/messages/" .. ngx.escape_uri(id) .. "?format=full",
                { headers = auth })
            if not full then return msgs, "Gmail: couldn't read a message", ferr end
            local h = {}
            for _, x in ipairs(full.payload and full.payload.headers or {}) do h[tostring(x.name):lower()] = x.value end
            local from, from_name = address(h.from)
            local ms = tonumber(full.internalDate)
            msgs[#msgs + 1] = { external_id = "gmail:" .. id, from_address = from, from_name = from_name,
                to_address = h.to, subject = h.subject,
                received_at = ms and os.date("!%Y-%m-%dT%H:%M:%SZ", math.floor(ms / 1000)) or h.date,
                sender_verified = dmarc_pass(h["authentication-results"]),
                body_text = gmail_text(full.payload) or full.snippet or "",
                cursor = ms and { after = math.floor(ms / 1000) - 1 } or nil }
        end
    end
    -- ponytail: at most 25,000 ids listed per run; a mailbox past that loses the oldest of them.
    if page then return msgs, "Gmail: more than 25,000 new messages; only the newest were read" end
    return msgs
end

local function fetch_m365(conn, secret, cursor, deadline, ns)
    local cfg = U.json(conn.config) or {}
    local tok, err = http_json(cfg.token_url or ("https://login.microsoftonline.com/" .. ngx.escape_uri(cfg.tenant_id)
        .. "/oauth2/v2.0/token"), { method = "POST", headers = { ["Content-Type"] = "application/x-www-form-urlencoded" },
        body = form({ grant_type = "client_credentials", client_id = cfg.client_id, client_secret = secret or "",
            scope = "https://graph.microsoft.com/.default" }) })
    if not tok or not tok.access_token then return nil, "Microsoft 365 sign-in failed", err or "no access token" end
    local api = (cfg.api_base or "https://graph.microsoft.com"):gsub("/+$", "")
    local headers = { Authorization = "Bearer " .. tok.access_token, Prefer = 'outlook.body-content-type="text"' }
    local since = cursor.since or os.date("!%Y-%m-%dT%H:%M:%SZ", ngx.time() - 7 * 86400)
    -- Oldest first from the last one read ("ge": its second is read again and skipped as known).
    local url = api .. "/v1.0/users/" .. ngx.escape_uri(cfg.mailbox) .. "/mailFolders/inbox/messages?$top=50"
        .. "&$orderby=receivedDateTime&$filter=" .. ngx.escape_uri("receivedDateTime ge " .. since)
        .. "&$select=id,internetMessageId,subject,from,toRecipients,receivedDateTime,body,internetMessageHeaders"
    local msgs = {}
    while url and #msgs < MAX_PER_RUN and not out_of_time(deadline) do
        local list, lerr = http_json(url, { headers = headers })
        if not list then
            if #msgs == 0 then return nil, "Microsoft 365: couldn't list messages", lerr end
            return msgs, "Microsoft 365: couldn't list messages", lerr
        end
        local page, ext = type(list.value) == "table" and list.value or {}, {}
        for _, m in ipairs(page) do ext[#ext + 1] = tostring(m.internetMessageId or m.id) end
        local known = known_ids(ns, "m365:", ext)
        for i, m in ipairs(page) do
            if #msgs >= MAX_PER_RUN then break end
            if not known[ext[i]] then
                local f = type(m.from) == "table" and m.from.emailAddress or {}
                local to, auth = {}, nil
                for _, r in ipairs(m.toRecipients or {}) do to[#to + 1] = r.emailAddress and r.emailAddress.address end
                for _, h in ipairs(type(m.internetMessageHeaders) == "table" and m.internetMessageHeaders or {}) do
                    if tostring(h.name):lower() == "authentication-results" then auth = auth or h.value end
                end
                local body = type(m.body) == "table" and m.body or {}
                msgs[#msgs + 1] = { external_id = "m365:" .. ext[i],
                    from_address = f.address and tostring(f.address):lower(), from_name = f.name,
                    to_address = table.concat(to, ", "), subject = m.subject, received_at = m.receivedDateTime,
                    sender_verified = dmarc_pass(auth),
                    body_text = body.contentType == "html" and strip_html(body.content or "") or (body.content or ""),
                    cursor = m.receivedDateTime and { since = m.receivedDateTime } or nil }
            end
        end
        url = list["@odata.nextLink"]
    end
    return msgs
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

--- Any text from a mailbox: valid UTF-8, at most n bytes (fits VARCHAR(n)).
local function clean(v, n)
    if v == nil or v == db.NULL then return nil end
    return U.cut(U.utf8(v), n)
end

function M.ingest(ns, conn, m)
    m.external_id, m.subject = clean(m.external_id, 255), clean(m.subject, 2000)
    m.from_address, m.from_name = clean(m.from_address, 255), clean(m.from_name, 255)
    m.to_address, m.body_text = clean(m.to_address, 4000), clean(m.body_text or "", 60000)
    local deal_uuid, matched_by = match_deal(ns, m)
    local lead_uuid = not deal_uuid and match_lead(ns, m) or nil
    if lead_uuid then matched_by = "lead" end
    local row = db.query([[
        INSERT INTO property_deals_inbound_messages (namespace_id, connector_uuid, external_id, from_address, from_name,
            to_address, subject, received_at, body_text, deal_uuid, matched_by, lead_uuid, sender_verified)
        VALUES (?, ?, ?, ?, ?, ?, ?, ?::timestamptz, ?, ?, ?, ?, ?)
        ON CONFLICT (namespace_id, external_id) DO NOTHING RETURNING *
    ]], ns, conn and conn.uuid or db.NULL, m.external_id, m.from_address or db.NULL,
        m.from_name or db.NULL, m.to_address or db.NULL, m.subject or db.NULL, received(m.received_at),
        m.body_text, deal_uuid or db.NULL, matched_by or db.NULL, lead_uuid or db.NULL,
        -- Pasted by a person (no connector): they vouch for the sender.
        not conn or m.sender_verified == true)[1]
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

--- A message that couldn't be stored: keep who / what / when (matched_by "error") so it isn't lost silently.
local function record_failed(ns, conn, m)
    local ok, err = pcall(db.query, [[
        INSERT INTO property_deals_inbound_messages (namespace_id, connector_uuid, external_id, from_address, subject,
            matched_by)
        VALUES (?, ?, ?, ?, ?, 'error') ON CONFLICT (namespace_id, external_id) DO NOTHING
    ]], ns, conn.uuid, clean(m.external_id, 255) or ("error:" .. ngx.now()), clean(m.from_address, 255) or db.NULL,
        clean(m.subject, 2000) or db.NULL)
    if not ok then ngx.log(ngx.ERR, "[property_deals] mail: could not record a failed message: ", tostring(err)) end
end

--- Fetch new mail for one connector. opts: { deadline (ngx.now() based) | budget (seconds, default 240) }
-- @return { fetched, stored, matched, failed, error? } | nil, error (both safe to show)
function M.sync(ns, conn, opts)
    opts = opts or {}
    local deadline = opts.deadline or (ngx.now() + (opts.budget or 240))
    local secret = not null(conn.secret_sealed) and Box.open(conn.secret_sealed, PURPOSE) or nil
    local cursor = U.json(conn.cursor)
    if type(cursor) ~= "table" then cursor = {} end
    local ok, msgs, err, raw = pcall(FETCH[conn.kind], conn, secret, cursor, deadline, ns)
    if not ok then msgs, err, raw = nil, "mail sync failed", msgs end
    if err then
        ngx.log(ngx.WARN, "[property_deals] mail ", conn.kind, " ", conn.uuid, ": ", err, ": ", tostring(raw))
    end
    if not msgs then
        db.update("property_deals_mail_connectors", { last_error = err, updated_at = db.raw("NOW()") },
            { id = conn.id })
        return nil, err
    end
    local fetched, stored, matched, failed = 0, 0, 0, 0
    for _, m in ipairs(msgs) do
        if not m.skip then
            fetched = fetched + 1
            local iok, r = pcall(M.ingest, ns, conn, m)
            if not iok then
                failed = failed + 1
                ngx.log(ngx.ERR, "[property_deals] mail ", conn.uuid, ": message ", tostring(m.external_id),
                    " could not be stored: ", tostring(r))
                record_failed(ns, conn, m)
            elseif r then
                stored = stored + 1
                if not null(r.deal_uuid) then matched = matched + 1 end
            end
        end
        -- Processed (or kept as failed): the next run starts after it.
        for k, v in pairs(m.cursor or {}) do cursor[k] = v end
    end
    if failed > 0 and not err then
        err = failed .. " message(s) could not be stored; they are listed with matched_by \"error\""
    end
    db.update("property_deals_mail_connectors", { cursor = cjson.encode(cursor), last_synced_at = db.raw("NOW()"),
        last_error = err or db.NULL, updated_at = db.raw("NOW()") }, { id = conn.id })
    return { fetched = fetched, stored = stored, matched = matched, failed = failed, error = err }
end

--- Every enabled connector, each in its share of the time budget; one failing never stops the others.
function M.sync_all(ns, opts)
    local deadline = ngx.now() + ((opts or {}).budget or 240)
    local out = { connectors = 0, stored = 0, errors = 0 }
    local conns = db.query([[SELECT * FROM property_deals_mail_connectors WHERE namespace_id = ? AND enabled
        ORDER BY last_synced_at NULLS FIRST]], ns)
    for i, c in ipairs(conns) do
        out.connectors = out.connectors + 1
        ngx.update_time()
        local share = ngx.now() + math.max(0, deadline - ngx.now()) / (#conns - i + 1)
        local ok, r = pcall(M.sync, ns, c, { deadline = share })
        if not ok then
            ngx.log(ngx.ERR, "[property_deals] mail sync ", c.uuid, ": ", tostring(r))
            pcall(db.update, "property_deals_mail_connectors", { last_error = "mail sync failed",
                updated_at = db.raw("NOW()") }, { id = c.id })
        end
        if ok and r then out.stored = out.stored + r.stored end
        if not (ok and r) or r.error then out.errors = out.errors + 1 end
    end
    return out
end

return M
