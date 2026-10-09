--[[
    Custom domains for public forms
    ===============================

    A workspace connects one domain (e.g. forms.acme.com) and its form links
    become https://forms.acme.com/f/<id>.

    1. An owner/admin enters the domain: a form_domains row, status "pending",
       with a random token.
    2. They add two DNS records:
         CNAME  forms.acme.com                    -> FORMS_DOMAIN_TARGET (the platform's edge;
                                                     an IP target means an A record instead)
         TXT    _opsapi-challenge.forms.acme.com  =  opsapi-verify=<token>
    3. check() looks both up on public resolvers (DOMAIN_VERIFY_RESOLVERS,
       default 1.1.1.1 and 8.8.8.8). The TXT record is the proof of control:
       the edge is shared with other sites, so "it points at the edge" alone
       proves nothing. Both found -> "active". A workspace that had the same
       domain active loses it: whoever proves control now wins (as on Vercel).
       A definite "records gone" sends an active domain back to pending, so
       links fall back to the platform's host instead of breaking; a lookup
       that fails changes nothing.
    4. An active domain:
       - is used by share links (FormQueries.present);
       - serves only its own workspace's forms: the public API checks the
         request's Origin (namespace_of), and the dashboard serves only /f/*
         there (opsapi-dashboard/proxy.ts);
       - gets 200 from GET /api/v2/public/form-domains/check?domain=, the
         edge's "may I get a certificate for this host?" question (Caddy
         on_demand_tls ask, lua-resty-auto-ssl allow_domain, ...).
    The hourly job re-checks pending domains for 7 days and active ones daily.
]]

local Domains = {}

Domains.TXT_PREFIX = "_opsapi-challenge."
Domains.TXT_VALUE = "opsapi-verify="
Domains.CACHE_SECONDS = 30

local function db() return require("lapis.db") end

local function nonnull(v)
    if v == nil or v == ngx.null then return nil end
    return v
end

local function strip(host)
    return (tostring(host or ""):lower():gsub("%.$", ""))
end

local function host_of(url)
    return type(url) == "string" and url:lower():match("^%a+://([^/:]+)") or nil
end

--- The edge customers point their domain at, or nil (custom domains off).
function Domains.target()
    local t = os.getenv("FORMS_DOMAIN_TARGET")
    t = t and strip(t:gsub("^%s+", ""):gsub("%s+$", ""))
    return (t and t ~= "") and t or nil
end

--- "forms.Acme.com", "https://forms.acme.com/x" -> "forms.acme.com"; nil, why for anything else.
function Domains.normalize(raw)
    if type(raw) ~= "string" then return nil, "enter a domain such as forms.example.com" end
    local d = raw:lower():gsub("^%s+", ""):gsub("%s+$", "")
    d = d:gsub("^%a+://", ""):gsub("[/?#].*$", ""):gsub(":%d+$", "")
    d = strip(d)
    if d == "" then return nil, "enter a domain such as forms.example.com" end
    if d:find("[^%w%.%-]") then
        return nil, "use letters, digits, dots and hyphens only (an international name in its xn-- form)"
    end
    if d:match("^[%d%.]+$") then return nil, "use a domain name, not an IP address" end
    if #d > 253 or not d:find("%.") or d:find("%.%.") or d:match("^%.") then
        return nil, "that isn't a valid domain"
    end
    for label in d:gmatch("[^.]+") do
        if #label > 63 or label:match("^%-") or label:match("%-$") then return nil, "that isn't a valid domain" end
    end
    if not d:match("%.(%a[%w%-]*)$") then return nil, "that isn't a valid domain" end
    return d
end

-- ── DNS ──────────────────────────────────────────────────────────────────

local function resolvers()
    local list = {}
    for ip in (os.getenv("DOMAIN_VERIFY_RESOLVERS") or "1.1.1.1,8.8.8.8"):gmatch("[^,%s]+") do
        list[#list + 1] = ip
    end
    return list
end

-- @return answers ({} when the name has none) | nil, err (the lookup itself failed)
local function lookup(name, qtype)
    local Resolver = require("resty.dns.resolver")
    local r, err = Resolver:new({ nameservers = resolvers(), retrans = 2, timeout = 3000 })
    if not r then return nil, err end
    local answers, qerr = r:query(name, { qtype = qtype })
    if not answers then return nil, qerr end
    if answers.errcode == 3 then return {} end -- NXDOMAIN: simply no records
    if answers.errcode then return nil, answers.errstr or ("DNS error " .. answers.errcode) end
    return answers
end

--- What DNS says about `domain` now.
-- @return { owned = bool, routed = bool } | nil, err
function Domains.dns(domain, token, target)
    local Resolver = require("resty.dns.resolver")
    local txt, terr = lookup(Domains.TXT_PREFIX .. domain, Resolver.TYPE_TXT)
    if not txt then return nil, terr end
    local owned = false
    for _, a in ipairs(txt) do
        local values = type(a.txt) == "table" and a.txt or { a.txt }
        for _, v in ipairs(values) do
            if v == Domains.TXT_VALUE .. token then owned = true end
        end
    end
    -- Routed: the CNAME chain reaches the target, or the domain has one of its addresses.
    local ans, aerr = lookup(domain, Resolver.TYPE_A)
    if not ans then return nil, aerr end
    local routed, addresses = false, {}
    for _, a in ipairs(ans) do
        if a.cname and strip(a.cname) == target then routed = true end
        if a.address then addresses[a.address] = true end
    end
    if not routed then
        local wanted = { { address = target } }
        if not target:match("^[%d%.]+$") then
            wanted = lookup(target, Resolver.TYPE_A)
            if not wanted then return nil, "couldn't look up " .. target end
        end
        for _, a in ipairs(wanted) do
            if a.address and addresses[a.address] then routed = true end
        end
    end
    return { owned = owned, routed = routed }
end

-- ── Caches (per worker; a change elsewhere shows within CACHE_SECONDS) ───

local by_host = require("resty.lrucache").new(2000) -- host -> namespace_id | false
local by_ns = require("resty.lrucache").new(2000)   -- namespace_id -> host | false

--- The workspace an active custom domain belongs to, or nil.
function Domains.namespace_of(host)
    host = strip(host)
    if host == "" then return nil end
    local v = by_host:get(host)
    if v == nil then
        local row = db().query("SELECT namespace_id FROM form_domains WHERE domain = ? AND status = 'active'", host)[1]
        v = row and tonumber(row.namespace_id) or false
        by_host:set(host, v, Domains.CACHE_SECONDS)
    end
    return v or nil
end

--- A workspace's active custom domain, or nil.
function Domains.active_for(namespace_id)
    namespace_id = tonumber(namespace_id)
    if not namespace_id then return nil end
    local v = by_ns:get(namespace_id)
    if v == nil then
        local ok, rows = pcall(db().query,
            "SELECT domain FROM form_domains WHERE namespace_id = ? AND status = 'active'", namespace_id)
        v = ok and rows[1] and rows[1].domain or false
        by_ns:set(namespace_id, v, Domains.CACHE_SECONDS)
    end
    return v or nil
end

local function forget(namespace_id, domain)
    by_ns:delete(tonumber(namespace_id))
    if domain then by_host:delete(domain) end
end

-- ── Admin ────────────────────────────────────────────────────────────────

local function row_of(namespace_id)
    return db().query("SELECT * FROM form_domains WHERE namespace_id = ?", namespace_id)[1]
end

local function present(row)
    local target = Domains.target()
    local out = { available = target ~= nil, target = target }
    if not row then return out end
    out.domain = row.domain
    out.status = row.status
    out.last_error = nonnull(row.last_error)
    out.checked_at = nonnull(row.checked_at)
    out.verified_at = nonnull(row.verified_at)
    local records = {}
    if target then
        records[1] = { type = target:match("^[%d%.]+$") and "A" or "CNAME", name = row.domain, value = target }
    end
    records[#records + 1] = { type = "TXT", name = Domains.TXT_PREFIX .. row.domain,
                              value = Domains.TXT_VALUE .. row.token }
    out.records = setmetatable(records, require("lib.forms.json").array_mt)
    return out
end

function Domains.get(namespace_id)
    return present(row_of(namespace_id))
end

--- Look the workspace's domain up now and update it.
-- @return the domain (as get) | nil, err, status
function Domains.check(namespace_id)
    local row = row_of(namespace_id)
    if not row then return nil, "no custom domain is set up", 404 end
    local target = Domains.target()
    if not target then return nil, "custom domains aren't set up on this platform", 409 end
    local found, err = Domains.dns(row.domain, row.token, target)
    if not found then
        db().query("UPDATE form_domains SET checked_at = NOW(), last_error = ? WHERE id = ?",
            "Couldn't look up DNS just now (" .. tostring(err) .. "). Try again in a minute.", row.id)
        return Domains.get(namespace_id)
    end
    if found.owned and found.routed then
        db().query("BEGIN")
        local ok = pcall(function()
            -- Whoever proves control now wins: another workspace's claim goes back to pending.
            local others = db().query([[UPDATE form_domains SET status = 'pending', updated_at = NOW(),
                last_error = 'Another workspace proved control of this domain and connected it.'
                WHERE domain = ? AND id <> ? AND status = 'active' RETURNING namespace_id]], row.domain, row.id)
            for _, o in ipairs(others) do forget(o.namespace_id) end
            db().query([[UPDATE form_domains SET status = 'active', last_error = NULL, checked_at = NOW(),
                verified_at = COALESCE(verified_at, NOW()), updated_at = NOW() WHERE id = ?]], row.id)
        end)
        db().query(ok and "COMMIT" or "ROLLBACK")
        -- Only another workspace verifying the same domain at the same moment gets here.
        if not ok then return nil, "couldn't connect the domain just now; try again", 409 end
    else
        local why = {}
        if not found.routed then why[#why + 1] = row.domain .. " doesn't point at " .. target .. " yet." end
        if not found.owned then
            why[#why + 1] = "The TXT record " .. Domains.TXT_PREFIX .. row.domain .. " isn't there yet."
        end
        why[#why + 1] = "New DNS records can take from a few minutes to a few hours to show."
        db().query([[UPDATE form_domains SET status = 'pending', last_error = ?, checked_at = NOW(),
            verified_at = NULL, updated_at = NOW()
            WHERE id = ?]], table.concat(why, " "), row.id)
    end
    forget(namespace_id, row.domain)
    return Domains.get(namespace_id)
end

--- Connect `raw` to the workspace (replacing its current domain) and check it.
-- @param reserved_urls addresses that can't be claimed (the dashboard's own), may hold nils
function Domains.claim(namespace_id, actor_uuid, raw, reserved_urls)
    if not Domains.target() then return nil, "custom domains aren't set up on this platform", 409 end
    local domain, err = Domains.normalize(raw)
    if not domain then return nil, err, 400 end
    local reserved = { [Domains.target()] = true }
    for _, name in ipairs({ "FRONTEND_URL", "OPSAPI_PUBLIC_URL", "API_URL" }) do
        local h = host_of(os.getenv(name))
        if h then reserved[h] = true end
    end
    for _, url in pairs(reserved_urls or {}) do
        local h = host_of(url)
        if h then reserved[h] = true end
    end
    if reserved[domain] then return nil, "that's the platform's own address", 400 end
    local cur = row_of(namespace_id)
    if cur and cur.domain == domain then return Domains.check(namespace_id) end
    db().query([[
        INSERT INTO form_domains (namespace_id, domain, token, created_by_uuid)
        VALUES (?, ?, ?, ?)
        ON CONFLICT (namespace_id) DO UPDATE SET domain = EXCLUDED.domain, token = EXCLUDED.token,
            status = 'pending', last_error = NULL, checked_at = NULL, verified_at = NULL,
            created_by_uuid = EXCLUDED.created_by_uuid, created_at = NOW(), updated_at = NOW()
    ]], namespace_id, domain, (require("helper.global").generateUUID():gsub("%-", "")), actor_uuid)
    forget(namespace_id, cur and cur.domain)
    return Domains.check(namespace_id) -- the records may be there already
end

function Domains.remove(namespace_id)
    local row = db().query("DELETE FROM form_domains WHERE namespace_id = ? RETURNING domain", namespace_id)[1]
    forget(namespace_id, row and row.domain)
    return row ~= nil
end

--- Hourly: pending domains for 7 days after they were added, active ones daily.
function Domains.maintain(limit)
    if not Domains.target() then return 0 end
    local rows = db().query([[
        SELECT namespace_id FROM form_domains
        WHERE (status = 'pending' AND created_at > NOW() - INTERVAL '7 days'
               AND (checked_at IS NULL OR checked_at < NOW() - INTERVAL '50 minutes'))
           OR (status = 'active' AND checked_at < NOW() - INTERVAL '1 day')
        ORDER BY checked_at NULLS FIRST LIMIT ?
    ]], tonumber(limit) or 50)
    for _, r in ipairs(rows) do
        local ok, err = pcall(Domains.check, r.namespace_id)
        if not ok then ngx.log(ngx.WARN, "[forms] domain check failed: ", tostring(err)) end
    end
    return #rows
end

return Domains
