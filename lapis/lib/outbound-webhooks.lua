--[[
    Workspace (outbound) webhooks — sending
    =======================================

    A workspace registers URLs that receive its events (invoice.updated,
    crm.lead.created, ...). Each webhook is an event subscriber
    ("webhook.<uuid>", scoped to its namespace) in helper.plugin-events, so it
    shares that outbox: transactional capture, retries with backoff, dead
    letters, purge. CRUD lives in queries/NamespaceWebhookQueries.lua; this
    module is the HTTP side.

    The URL is tenant input, so every request is SSRF-guarded: https only, the
    host is resolved here and EVERY address must be public (no loopback,
    private, link-local — e.g. cloud metadata 169.254.169.254 — CGNAT or
    reserved ranges), and the connection goes to the checked IP (SNI/Host
    keep the name), so DNS can't be swapped between check and connect.
    OPSAPI_WEBHOOKS_ALLOW_PRIVATE=true lifts this for local development only.

    Request:  POST <url>, JSON body
      { "id": "<event uuid>", "type": "invoice.updated", "created_at": "...Z",
        "namespace": { "id": "<uuid>", "slug": "..." },
        "data": { "object": { ...row... }, "changes": { "status": { "from": "sent", "to": "paid" } } } }
    Headers:  X-Opsapi-Event, X-Opsapi-Delivery, X-Opsapi-Timestamp,
              X-Opsapi-Signature-256: sha256=HMAC_SHA256(secret, timestamp .. "." .. body)
    A 2xx response is success; anything else (or a timeout) is retried.
]]

local cjson = require("cjson")

local Webhooks = {}

local CONNECT_MS, SEND_MS, READ_MS = 3000, 5000, 10000

local function allow_private()
    return os.getenv("OPSAPI_WEBHOOKS_ALLOW_PRIVATE") == "true"
end

-- ---------------------------------------------------------------------------
-- URL policy
-- ---------------------------------------------------------------------------

local function ipv4(host)
    local a, b, c, d = host:match("^(%d+)%.(%d+)%.(%d+)%.(%d+)$")
    if not a then return nil end
    a, b, c, d = tonumber(a), tonumber(b), tonumber(c), tonumber(d)
    if a > 255 or b > 255 or c > 255 or d > 255 then return nil end
    return a, b, c, d
end

--- Is this IPv4 address routable on the public internet?
function Webhooks.isPublicIPv4(ip)
    local a, b, c = ipv4(ip)
    if not a then return false end
    return not (
        a == 0 or a == 10 or a == 127 or a >= 224                     -- this-net, private, loopback, multicast/reserved
        or (a == 100 and b >= 64 and b <= 127)                        -- CGNAT
        or (a == 169 and b == 254)                                    -- link-local, cloud metadata
        or (a == 172 and b >= 16 and b <= 31)                         -- private
        or (a == 192 and b == 168)                                    -- private
        or (a == 192 and b == 0 and (c == 0 or c == 2))               -- IETF, TEST-NET-1
        or (a == 198 and (b == 18 or b == 19))                        -- benchmarking
        or (a == 198 and b == 51 and c == 100) or (a == 203 and b == 0 and c == 113) -- TEST-NET-2/3
    )
end

--- Parse and vet a webhook URL. Returns { scheme, host, port, path } or nil, reason.
function Webhooks.parseUrl(url)
    if type(url) ~= "string" or #url > 2000 then return nil, "must be a URL of at most 2000 characters" end
    local scheme, authority, rest = url:match("^(%a+)://([^/?#]+)(.*)$")
    if not scheme then return nil, "must be an absolute URL (https://…)" end
    scheme = scheme:lower()
    if scheme ~= "https" and not (scheme == "http" and allow_private()) then
        return nil, "must use https"
    end
    if authority:find("@", 1, true) then return nil, "must not contain credentials" end
    if authority:find("[", 1, true) then return nil, "IPv6 addresses are not supported" end
    local host, port = authority:match("^([^:]+):?(%d*)$")
    if not host then return nil, "has an invalid host" end
    host = host:lower()
    port = tonumber(port) or (scheme == "https" and 443 or 80)
    if port < 1 or port > 65535 then return nil, "has an invalid port" end
    if not allow_private() then
        if ipv4(host) and not Webhooks.isPublicIPv4(host) then return nil, "must not point to a private address" end
        if host == "localhost" or host:match("%.localhost$") or host:match("%.local$") or host:match("%.internal$")
            or host:match("%.svc$") or host:match("%.cluster%.local$") or not host:find(".", 1, true) then
            return nil, "must point to a public host"
        end
    end
    local path = rest:gsub("#.*$", "")
    if path == "" or path:sub(1, 1) == "?" then path = "/" .. path end
    return { scheme = scheme, host = host, port = port, path = path }
end

-- ---------------------------------------------------------------------------
-- DNS (resolve once, check every answer, connect to what was checked)
-- ---------------------------------------------------------------------------

local nameservers
local function get_nameservers()
    if nameservers then return nameservers end
    nameservers = {}
    local f = io.open("/etc/resolv.conf", "r")
    if f then
        for line in f:lines() do
            local ns = line:match("^%s*nameserver%s+(%S+)")
            if ns and ipv4(ns) then nameservers[#nameservers + 1] = ns end
        end
        f:close()
    end
    if #nameservers == 0 then nameservers = { "8.8.8.8" } end
    return nameservers
end

local function resolve(host)
    if ipv4(host) then return { host } end
    local resolver = require("resty.dns.resolver")
    local r, err = resolver:new({ nameservers = get_nameservers(), retrans = 2, timeout = 2000 })
    if not r then return nil, "DNS unavailable: " .. tostring(err) end
    local answers, qerr = r:query(host, { qtype = r.TYPE_A })
    if not answers then return nil, "DNS lookup failed: " .. tostring(qerr) end
    if answers.errcode then return nil, "DNS lookup failed: " .. tostring(answers.errstr) end
    local ips = {}
    for _, a in ipairs(answers) do
        if a.address then ips[#ips + 1] = a.address end
    end
    if #ips == 0 then return nil, "host has no IPv4 address" end
    return ips
end

-- ---------------------------------------------------------------------------
-- Signing + sending
-- ---------------------------------------------------------------------------

local function hex(bin)
    return (bin:gsub(".", function(ch) return ("%02x"):format(ch:byte()) end))
end

--- "sha256=<hex>" of HMAC-SHA256(secret, timestamp .. "." .. body).
function Webhooks.sign(secret, timestamp, body)
    return "sha256=" .. hex(require("openssl.hmac").new(secret, "sha256"):final(timestamp .. "." .. body))
end

--- A new signing secret ("whsec_" + 32 random bytes, hex).
function Webhooks.newSecret()
    local bytes = require("resty.random").bytes(32, true)
    assert(bytes, "no secure random source")
    return "whsec_" .. hex(bytes)
end

--- POST a JSON body to a webhook URL (SSRF-guarded).
-- @return ok, error, response_status, duration_ms
function Webhooks.post(url, secret, event_type, delivery_id, body)
    local target, why = Webhooks.parseUrl(url)
    if not target then return false, "URL " .. why end

    local ips, err = resolve(target.host)
    if not ips then return false, err end
    if not allow_private() then
        for _, ip in ipairs(ips) do
            if not Webhooks.isPublicIPv4(ip) then
                return false, target.host .. " resolves to a private address (" .. ip .. "); refusing to send"
            end
        end
    end

    local timestamp = tostring(ngx.time())
    local httpc = require("resty.http").new()
    httpc:set_timeouts(CONNECT_MS, SEND_MS, READ_MS)
    local started = ngx.now()
    local ok, cerr = httpc:connect({
        scheme = target.scheme,
        host = ips[1],
        port = target.port,
        ssl_server_name = target.host,
        ssl_verify = target.scheme == "https",
    })
    if not ok then
        return false, "could not connect: " .. tostring(cerr), nil, math.floor((ngx.now() - started) * 1000)
    end
    local default_port = target.port == (target.scheme == "https" and 443 or 80)
    local res, rerr = httpc:request({
        method = "POST",
        path = target.path,
        body = body,
        headers = {
            ["Host"] = default_port and target.host or (target.host .. ":" .. target.port),
            ["Content-Type"] = "application/json",
            ["User-Agent"] = "OpsAPI-Webhooks/1",
            ["X-Opsapi-Event"] = event_type,
            ["X-Opsapi-Delivery"] = tostring(delivery_id),
            ["X-Opsapi-Timestamp"] = timestamp,
            ["X-Opsapi-Signature-256"] = Webhooks.sign(secret, timestamp, body),
        },
    })
    local ms
    if res then
        pcall(res.read_body, res) -- drain so the connection can be reused
        ms = math.floor((ngx.now() - started) * 1000)
        httpc:set_keepalive(10000, 16)
    else
        ms = math.floor((ngx.now() - started) * 1000)
        httpc:close()
        return false, "request failed: " .. tostring(rerr), nil, ms
    end
    if res.status >= 200 and res.status < 300 then
        return true, nil, res.status, ms
    end
    return false, "receiver answered HTTP " .. res.status, res.status, ms
end

--- The JSON body for one event (the public, documented payload).
function Webhooks.payload(event)
    local data = { object = event.data or cjson.empty_array }
    if event.changes then data.changes = event.changes end
    return cjson.encode({
        id = event.id,
        type = event.type,
        created_at = event.created_at,
        namespace = event.namespace,
        data = data,
    })
end

local function load_webhook(uuid)
    local db = require("lapis.db")
    local row = db.query([[
        SELECT w.*, n.uuid AS namespace_uuid, n.slug AS namespace_slug
        FROM namespace_webhooks w JOIN namespaces n ON n.id = w.namespace_id
        WHERE w.uuid::text = ?
    ]], uuid)[1]
    if not row then return nil end
    row.secret = require("helper.global").decryptSecret(row.encrypted_secret)
    return row
end

--- Deliver one outbox event to a webhook (called by the plugin-events
-- dispatcher for subscriber "webhook.<uuid>").
-- @return ok, error, response_status, duration_ms
function Webhooks.deliverEvent(webhook_uuid, e, delivery)
    local db = require("lapis.db")
    if not e then return true end -- event already purged
    local webhook = load_webhook(webhook_uuid)
    -- Deleted or disabled since the event was queued: nothing to send.
    if not webhook or not webhook.is_active then return true end
    -- Belt and braces: the fan-out is namespace-filtered already.
    if tonumber(e.namespace_id) ~= tonumber(webhook.namespace_id) then
        ngx.log(ngx.ERR, "[webhooks] refusing cross-namespace delivery for webhook ", webhook_uuid)
        return true
    end
    local created_at = db.query([[SELECT to_char(?::timestamptz AT TIME ZONE 'UTC',
        'YYYY-MM-DD"T"HH24:MI:SS"Z"') AS t]], e.created_at)[1].t
    local function decoded(v)
        if type(v) == "string" then return cjson.decode(v) end
        return v
    end
    local body = Webhooks.payload({
        id = e.uuid,
        type = e.event,
        created_at = created_at,
        namespace = { id = webhook.namespace_uuid, slug = webhook.namespace_slug },
        data = decoded(e.data),
        changes = decoded(e.changes),
    })
    return Webhooks.post(webhook.url, webhook.secret, e.event, delivery.id, body)
end

--- Send a signed "webhook.test" ping right now (the "Send test" button).
function Webhooks.sendTest(webhook_uuid)
    local webhook = load_webhook(webhook_uuid)
    if not webhook then return false, "webhook not found" end
    local id = require("resty.string").to_hex(require("resty.random").bytes(8))
    local body = Webhooks.payload({
        id = "test_" .. id,
        type = "webhook.test",
        created_at = os.date("!%Y-%m-%dT%H:%M:%SZ"),
        namespace = { id = webhook.namespace_uuid, slug = webhook.namespace_slug },
        data = { message = "Test event from OpsAPI. Your endpoint is reachable and the signature can be verified." },
    })
    return Webhooks.post(webhook.url, webhook.secret, "webhook.test", "test_" .. id, body)
end

return Webhooks
