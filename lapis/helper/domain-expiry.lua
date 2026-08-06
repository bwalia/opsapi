--[[
    Domain Expiry Engine
    ====================

    Auto-detects, per domain:
      - Registration expiry  → RDAP lookup (https://rdap.org bootstrap, follows
        redirects to the authoritative registry RDAP server). Also pulls the
        registrar name and registry status.
      - SSL/TLS expiry       → live TLS handshake to the host:443 using an
        ngx cosocket, reading the peer certificate's notAfter via
        resty.openssl (ssl_verify off so even an expired/invalid cert is read).

    Computes a lifecycle status (active | expiring_soon | expired | error),
    persists it via DomainQueries.applyExpiryResult, and best-effort raises a
    notification for the domain owner when within the alert threshold. Every
    step is guarded — a lookup failure records last_check_error and never throws.
]]

local DomainQueries = require("queries.DomainQueries")
local db = require("lapis.db")

local DomainExpiry = {}

--------------------------------------------------------------------------------
-- Helpers
--------------------------------------------------------------------------------

-- Normalise an ISO-8601 timestamp ("2025-08-06T12:00:00Z" / "...+00:00") into a
-- Postgres-friendly "YYYY-MM-DD HH:MM:SS". Returns nil if unparseable.
local function iso_to_pg(iso)
    if type(iso) ~= "string" then return nil end
    local y, mo, d, h, mi, s = iso:match("(%d%d%d%d)%-(%d%d)%-(%d%d)[Tt ](%d%d):(%d%d):(%d%d)")
    if not y then
        -- date only
        y, mo, d = iso:match("(%d%d%d%d)%-(%d%d)%-(%d%d)")
        if not y then return nil end
        return string.format("%s-%s-%s 00:00:00", y, mo, d)
    end
    return string.format("%s-%s-%s %s:%s:%s", y, mo, d, h, mi, s)
end

-- Days from now until a Postgres timestamp string (UTC). Negative = past.
local function days_until(pg_ts)
    if not pg_ts then return nil end
    local y, mo, d, h, mi, s = pg_ts:match("(%d+)%-(%d+)%-(%d+)%s+(%d+):(%d+):(%d+)")
    if not y then return nil end
    local target = os.time({
        year = tonumber(y), month = tonumber(mo), day = tonumber(d),
        hour = tonumber(h), min = tonumber(mi), sec = tonumber(s),
    })
    -- os.time treats the table as local time; good enough for day-granularity alerts.
    return math.floor((target - os.time()) / 86400)
end

local function http_client(timeout)
    local ok, http = pcall(require, "resty.http")
    if not ok then return nil, "resty.http not available" end
    local httpc = http.new()
    httpc:set_timeout(timeout or 15000)
    return httpc, nil
end

--------------------------------------------------------------------------------
-- RDAP: registration expiry
--------------------------------------------------------------------------------
function DomainExpiry.check_rdap(domain_name)
    local httpc, err = http_client(15000)
    if not httpc then return nil, err end

    local url = "https://rdap.org/domain/" .. domain_name
    local res
    for _ = 1, 5 do
        local r, rerr = httpc:request_uri(url, {
            method = "GET",
            headers = { ["Accept"] = "application/rdap+json" },
            ssl_verify = true,
        })
        if not r then return nil, "RDAP request failed: " .. tostring(rerr) end
        if r.status >= 300 and r.status < 400 then
            local loc = r.headers and (r.headers["Location"] or r.headers["location"])
            if not loc then return nil, "RDAP redirect without Location" end
            url = loc
        else
            res = r
            break
        end
    end
    if not res then return nil, "RDAP too many redirects" end
    if res.status == 404 then return nil, "Domain not found in RDAP" end
    if res.status >= 400 then return nil, "RDAP HTTP " .. tostring(res.status) end

    local cjson = require("cjson")
    local ok, data = pcall(cjson.decode, res.body or "")
    if not ok or type(data) ~= "table" then return nil, "RDAP non-JSON response" end

    local out = {}

    if type(data.events) == "table" then
        for _, ev in ipairs(data.events) do
            if ev.eventAction == "expiration" and ev.eventDate then
                out.registration_expires_at = iso_to_pg(ev.eventDate)
            end
        end
    end

    if type(data.status) == "table" then
        out.registrar_status = table.concat(data.status, ", ")
    end

    -- Registrar name from the entity with role "registrar".
    if type(data.entities) == "table" then
        for _, ent in ipairs(data.entities) do
            local roles = ent.roles or {}
            local is_registrar = false
            for _, role in ipairs(roles) do
                if role == "registrar" then is_registrar = true break end
            end
            if is_registrar and type(ent.vcardArray) == "table" and ent.vcardArray[2] then
                for _, field in ipairs(ent.vcardArray[2]) do
                    if field[1] == "fn" and field[4] then
                        out.registrar = field[4]
                        break
                    end
                end
            end
        end
    end

    if not out.registration_expires_at then
        return out, "RDAP had no expiration event"
    end
    return out, nil
end

--------------------------------------------------------------------------------
-- Live TLS handshake: SSL certificate expiry
--------------------------------------------------------------------------------
function DomainExpiry.check_ssl(host, port)
    -- Uses a raw TLS 1.2 ClientHello to read the cleartext Certificate message —
    -- see helper/tls-cert.lua for why (no cosocket→SSL bridge in this build).
    local TLSCert = require("helper.tls-cert")
    local info, err = TLSCert.fetch(host, port or 443, 8000)
    if not info then return nil, err end
    return {
        ssl_expires_at = os.date("!%Y-%m-%d %H:%M:%S", info.not_after),
        ssl_issuer = info.issuer,
    }, nil
end

--------------------------------------------------------------------------------
-- Best-effort notification for the domain owner
--------------------------------------------------------------------------------
local function notify_owner(domain, level, min_days)
    if not domain.owner_user_uuid or domain.owner_user_uuid == "" then return end
    local ok = pcall(function()
        -- notifications table is user-scoped (user_id FK). Resolve owner id.
        local users = db.query("SELECT id FROM users WHERE uuid = ? LIMIT 1", domain.owner_user_uuid)
        local user = users and users[1]
        if not user then return end

        -- Dedup: skip if an unread domain-expiry notice for this domain exists < 24h old.
        local recent = db.query([[
            SELECT id FROM notifications
            WHERE user_id = ? AND type = 'domain_expiry'
              AND related_entity_id = ?
              AND is_read = FALSE
              AND created_at > NOW() - INTERVAL '24 hours'
            LIMIT 1
        ]], user.id, domain.uuid)
        if recent and #recent > 0 then return end

        local Global = require("helper.global")
        local cjson = require("cjson")
        local title = (level == "expired") and ("Domain expired: " .. domain.domain_name)
            or ("Domain expiring soon: " .. domain.domain_name)
        local message
        if level == "expired" then
            message = domain.domain_name .. " has an expired registration or SSL certificate."
        else
            message = domain.domain_name .. " expires in " .. tostring(min_days) .. " day(s). Renew soon."
        end

        db.insert("notifications", {
            uuid = Global.generateUUID(),
            user_id = user.id,
            type = "domain_expiry",
            title = title,
            message = message,
            data = cjson.encode({ domain_uuid = domain.uuid, level = level, days = min_days }),
            related_entity_type = "domain",
            related_entity_id = domain.uuid,
            is_read = false,
            created_at = db.raw("NOW()"),
        })
    end)
    if not ok then
        ngx.log(ngx.WARN, "[domain-expiry] notification insert failed for ", domain.domain_name)
    end
end

--------------------------------------------------------------------------------
-- Refresh a single domain row (table from DB). Returns the updated row.
--------------------------------------------------------------------------------
function DomainExpiry.refresh(domain)
    local result = {}
    local errors = {}

    local rdap, rerr = DomainExpiry.check_rdap(domain.domain_name)
    if rdap then
        result.registration_expires_at = rdap.registration_expires_at
        result.registrar = rdap.registrar
        result.registrar_status = rdap.registrar_status
    end
    if rerr then table.insert(errors, "RDAP: " .. rerr) end

    local sslr, serr = DomainExpiry.check_ssl(domain.domain_name, 443)
    if sslr then
        result.ssl_expires_at = sslr.ssl_expires_at
        result.ssl_issuer = sslr.ssl_issuer
    end
    if serr then table.insert(errors, "SSL: " .. serr) end

    -- Compute status from the soonest of the two expiries.
    local threshold = tonumber(domain.alert_threshold_days) or 30
    local reg_days = days_until(result.registration_expires_at or domain.registration_expires_at)
    local ssl_days = days_until(result.ssl_expires_at or domain.ssl_expires_at)

    local min_days = nil
    for _, dgs in ipairs({ reg_days, ssl_days }) do
        if dgs ~= nil and (min_days == nil or dgs < min_days) then min_days = dgs end
    end

    local status
    if min_days ~= nil and min_days < 0 then
        status = "expired"
    elseif min_days ~= nil and min_days <= threshold then
        status = "expiring_soon"
    elseif #errors > 0 and not result.registration_expires_at and not result.ssl_expires_at then
        status = "error"
    else
        status = "active"
    end
    result.status = status
    result.error = (#errors > 0) and table.concat(errors, "; ") or nil

    local updated = DomainQueries.applyExpiryResult(domain.uuid, result)

    if status == "expired" then
        notify_owner(domain, "expired", min_days)
    elseif status == "expiring_soon" then
        notify_owner(domain, "expiring_soon", min_days)
    end

    return updated, result
end

--------------------------------------------------------------------------------
-- Bulk refresh every domain in a namespace. Returns a summary.
--------------------------------------------------------------------------------
function DomainExpiry.refresh_namespace(namespace_id)
    local domains = DomainQueries.getAllForNamespace(namespace_id)
    local summary = { checked = 0, expiring_soon = 0, expired = 0, errors = 0 }
    for _, domain in ipairs(domains or {}) do
        local ok, _, result = pcall(DomainExpiry.refresh, domain)
        summary.checked = summary.checked + 1
        if ok and result then
            if result.status == "expiring_soon" then summary.expiring_soon = summary.expiring_soon + 1 end
            if result.status == "expired" then summary.expired = summary.expired + 1 end
            if result.status == "error" then summary.errors = summary.errors + 1 end
        else
            summary.errors = summary.errors + 1
        end
    end
    return summary
end

return DomainExpiry
