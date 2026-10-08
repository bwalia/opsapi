--[[
    Billing & Entitlements — licence keys for desktop / self-hosted apps
    ====================================================================
    docs/BILLING_ENTITLEMENTS.md §4.2 / §6 / §7.

    A key looks like ABCDE-FGHJK-LMNPQ-RSTUV-WXYZ2 (25 characters from a
    32-letter alphabet without 0/O/1/I: 125 random bits). Only its SHA-256 and
    first group are stored; the key itself is shown once, at creation.

    Each machine that uses a key is an activation, identified by the SHA-256
    of a fingerprint the app sends. activate/validate return a signed licence
    file (ES256) the app verifies offline with the public JWKS.

    A licence's features = the customer's entitlements for the app, plus the
    licence's own plan. A licence tied to a subscription stops working when
    that subscription stops entitling.
]]

local db = require("lapis.db")
local cjson = require("cjson")
local Common = require("queries.FieldServiceCommon")
local Apps = require("queries.BillingAppQueries")
local Subs = require("queries.BillingSubscriptionQueries")
local ApiKey = require("helper.api-key")
local EntitlementService = require("helper.entitlement-service")
local Signing = require("lib.billing-signing")

local Licenses = {}

local ALPHABET = "ABCDEFGHJKLMNPQRSTUVWXYZ23456789"

function Licenses.generateKey()
    local random = require("resty.random")
    local bytes = random.bytes(25, true) or random.bytes(25)
    local chars = {}
    for i = 1, 25 do
        local n = bytes:byte(i) % 32 + 1 -- 256 = 8 x 32: no modulo bias
        chars[#chars + 1] = ALPHABET:sub(n, n)
        if i % 5 == 0 and i < 25 then chars[#chars + 1] = "-" end
    end
    return table.concat(chars)
end

--- Case, dashes and spaces don't matter when a customer types the key.
function Licenses.normalize(key)
    if type(key) ~= "string" then return nil end
    local k = key:upper():gsub("[^A-Z0-9]", "")
    if #k ~= 25 then return nil end
    return k
end

local LIST_SELECT = [[
    SELECT l.uuid, l.key_prefix, l.status, l.max_activations, l.expires_at, l.metadata, l.created_by,
           l.revoked_at, l.created_at, l.updated_at,
           a.uuid AS app_uuid, a.name AS app_name, p.uuid AS plan_uuid, p.plan_key, p.name AS plan_name,
           s.uuid AS subscription_uuid, c.uuid AS customer_uuid, c.external_id AS customer_external_id,
           c.email AS customer_email,
           (SELECT count(*) FROM billing_license_activations x
             WHERE x.license_id = l.id AND x.deactivated_at IS NULL)::int AS active_activations
    FROM billing_licenses l
    JOIN billing_apps a ON a.id = l.app_id
    JOIN customers c ON c.id = l.customer_id
    LEFT JOIN billing_plans p ON p.id = l.plan_id
    LEFT JOIN billing_subscriptions s ON s.id = l.subscription_id
]]

function Licenses.list(namespace_id, params)
    local where, vals = { "l.namespace_id = ?" }, { namespace_id }
    if Common.nilify(params.app) then
        where[#where + 1] = "(a.uuid = ? OR a.slug = ?)"
        vals[#vals + 1], vals[#vals + 2] = params.app, params.app
    end
    if Common.nilify(params.customer) then
        where[#where + 1] = "c.uuid = ?"
        vals[#vals + 1] = params.customer
    end
    if Common.nilify(params.status) then
        where[#where + 1] = "l.status = ?"
        vals[#vals + 1] = params.status
    end
    local page, per_page, offset = Common.paging(params)
    local sql = LIST_SELECT .. " WHERE " .. table.concat(where, " AND ")
    local total = db.query("SELECT count(*) AS n FROM (" .. sql .. ") x", unpack(vals))[1].n
    vals[#vals + 1], vals[#vals + 2] = per_page, offset
    local rows = db.query(sql .. " ORDER BY l.created_at DESC LIMIT ? OFFSET ?", unpack(vals))
    return Common.arr(rows), Common.meta(total, page, per_page)
end

function Licenses.get(namespace_id, uuid)
    local row = db.query(LIST_SELECT .. " WHERE l.namespace_id = ? AND l.uuid = ?", namespace_id, uuid)[1]
    if not row then return nil end
    row.activations = Common.arr(db.query([[
        SELECT x.uuid, x.name, x.platform, x.app_version, x.first_seen_at, x.last_seen_at, x.deactivated_at
        FROM billing_license_activations x JOIN billing_licenses l ON l.id = x.license_id
        WHERE l.uuid = ? ORDER BY x.deactivated_at IS NOT NULL, x.last_seen_at DESC]], uuid))
    return row
end

local function clean(b, partial)
    local f = {}
    if b.max_activations ~= nil then
        local n = Common.to_number(b.max_activations)
        if b.max_activations == cjson.null or b.max_activations == "" then
            f.max_activations = db.NULL
        elseif not n or n < 1 or n > 100000 or n ~= math.floor(n) then
            return nil, "max_activations must be a whole number from 1, or null for unlimited"
        else
            f.max_activations = n
        end
    end
    if b.expires_at ~= nil then
        local v = Common.nilify(b.expires_at)
        if v ~= nil and (type(v) ~= "string" or not v:match("^%d%d%d%d%-%d%d%-%d%d")) then
            return nil, "expires_at must be an ISO-8601 date/time, or null"
        end
        f.expires_at = v and db.raw(db.escape_literal(v) .. "::timestamptz") or db.NULL
    end
    if b.metadata ~= nil then
        if type(b.metadata) ~= "table" then return nil, "metadata must be an object" end
        f.metadata = db.raw(db.escape_literal(Signing.encode(b.metadata)) .. "::jsonb")
    end
    if partial and b.status ~= nil then
        -- revoke is its own action (irreversible); expiry comes from expires_at.
        if b.status ~= "active" and b.status ~= "suspended" then
            return nil, "status can be set to active or suspended (use revoke to revoke)"
        end
        f.status = b.status
    end
    return f
end

-- Bad timestamps are input errors, not 500s.
local function write(fn)
    local ok, res = pcall(fn)
    if ok then return res end
    local msg = tostring(res)
    if msg:find("invalid input syntax", 1, true) or msg:find("out of range", 1, true) then
        return nil, "expires_at must be a valid ISO-8601 date/time"
    end
    error(res)
end

--- Issue a licence. @return { license, key } (key shown once) | nil, err
function Licenses.create(namespace_id, actor, b)
    local app = Apps.find(namespace_id, b.app)
    if not app then return nil, "App not found" end
    local customer = Subs.customer(namespace_id, b.customer)
    if not customer then return nil, "Customer not found" end
    local f, err = clean(b, false)
    if not f then return nil, err end
    if Common.nilify(b.plan) then
        local plan = Subs.appPlan(app.id, b.plan)
        if not plan then return nil, "Plan not found in this app" end
        f.plan_id = plan.id
    end
    if Common.nilify(b.subscription) then
        local sub = db.query([[SELECT id FROM billing_subscriptions
            WHERE namespace_id = ? AND uuid = ? AND app_id = ? AND customer_id = ?]],
            namespace_id, b.subscription, app.id, customer.id)[1]
        if not sub then return nil, "Subscription not found for this customer and app" end
        f.subscription_id = sub.id
    end
    local key = Licenses.generateKey()
    f.uuid = Common.uuid()
    f.namespace_id, f.app_id, f.customer_id = namespace_id, app.id, customer.id
    f.key_hash = ApiKey.hash(Licenses.normalize(key))
    f.key_prefix = key:sub(1, 5)
    f.created_by = actor
    local ok, werr = write(function() return db.insert("billing_licenses", f) end)
    if not ok then return nil, werr end
    return { license = Licenses.get(namespace_id, f.uuid), key = key }
end

function Licenses.update(namespace_id, uuid, b)
    local f, err = clean(b, true)
    if not f then return nil, err end
    local lic = db.query("SELECT id, status FROM billing_licenses WHERE namespace_id = ? AND uuid = ?",
        namespace_id, uuid)[1]
    if not lic then return nil, "Licence not found" end
    if lic.status == "revoked" then return nil, "a revoked licence can't be changed" end
    if next(f) ~= nil then
        f.updated_at = db.raw("NOW()")
        local ok, werr = write(function() return db.update("billing_licenses", f, { id = lic.id }) end)
        if not ok then return nil, werr end
    end
    return Licenses.get(namespace_id, uuid)
end

--- Revoke for good: every activation ends and validation fails from now on.
function Licenses.revoke(namespace_id, uuid)
    return Common.transaction(function()
        local lic = db.query([[UPDATE billing_licenses SET status = 'revoked', revoked_at = NOW(), updated_at = NOW()
            WHERE namespace_id = ? AND uuid = ? AND status <> 'revoked' RETURNING id]], namespace_id, uuid)[1]
        if not lic then return nil, "Licence not found" end
        db.query([[UPDATE billing_license_activations SET deactivated_at = NOW()
            WHERE license_id = ? AND deactivated_at IS NULL]], lic.id)
        return Licenses.get(namespace_id, uuid)
    end)
end

--- Free a seat (e.g. a lost laptop).
function Licenses.removeActivation(namespace_id, uuid, activation_uuid)
    local res = db.query([[UPDATE billing_license_activations x SET deactivated_at = NOW()
        FROM billing_licenses l WHERE l.id = x.license_id AND l.namespace_id = ? AND l.uuid = ?
          AND x.uuid = ? AND x.deactivated_at IS NULL]], namespace_id, uuid, activation_uuid)
    if (res.affected_rows or 0) == 0 then return nil, "Activation not found" end
    return true
end

-- ---------------------------------------------------------------------------
-- Public: activate / validate / deactivate (publishable key + licence key)
-- Errors are { code, message, status } so apps can branch on `code`.
-- ---------------------------------------------------------------------------

local function failure(status, code, message)
    return nil, { status = status, code = code, message = message }
end

local INVALID = { 404, "invalid_license", "This licence key is not valid for this app" }

local function fingerprint_hash(fp)
    if type(fp) ~= "string" or #fp < 8 or #fp > 512 then return nil end
    return ApiKey.hash(fp)
end

-- The licence behind a key, if it may be used right now. Locks the row so
-- concurrent activations can't exceed max_activations.
local function usable(app, raw_key)
    local key = Licenses.normalize(raw_key)
    if not key then return failure(unpack(INVALID)) end
    local lic = db.query([[SELECT l.*, extract(epoch FROM l.expires_at)::bigint AS expires_epoch
        FROM billing_licenses l WHERE l.key_hash = ? AND l.app_id = ? FOR UPDATE]], ApiKey.hash(key), app.id)[1]
    if not lic then return failure(unpack(INVALID)) end
    if lic.status == "active" and lic.expires_epoch and tonumber(lic.expires_epoch) <= ngx.time() then
        db.query("UPDATE billing_licenses SET status = 'expired', updated_at = NOW() WHERE id = ?", lic.id)
        lic.status = "expired"
    end
    if lic.status ~= "active" then
        return failure(403, "license_" .. lic.status, "This licence is " .. lic.status)
    end
    if lic.subscription_id then
        local sub = db.query("SELECT status FROM billing_subscriptions WHERE id = ?", lic.subscription_id)[1]
        if not sub or (sub.status ~= "active" and sub.status ~= "trialing" and sub.status ~= "past_due") then
            return failure(403, "subscription_inactive", "The subscription behind this licence is not active")
        end
    end
    return lic
end

-- The signed licence file for an activation (docs §6).
local function license_file(app, lic, fp_hash)
    local customer = db.query("SELECT id, uuid, external_id FROM customers WHERE id = ?", lic.customer_id)[1]
    local ent = EntitlementService.resolve(app, customer)
    local plan = ent.plan
    if lic.plan_id then
        local p = db.query("SELECT uuid, plan_key, name, features FROM billing_plans WHERE id = ?", lic.plan_id)[1]
        if p then
            EntitlementService.merge(ent.features, Apps.catalog(app.id), p.features)
            plan = { uuid = p.uuid, key = p.plan_key, name = p.name }
        end
    end
    local now = ngx.time()
    local function cap(t)
        local e = tonumber(lic.expires_epoch)
        return (e and e < t) and e or t
    end
    local claims = {
        iss = EntitlementService.issuer(),
        aud = app.uuid,
        sub = customer.external_id or customer.uuid,
        lic = lic.uuid,
        fp = fp_hash,
        plan = plan and (plan.key or plan.uuid) or cjson.null,
        features = ent.features,
        iat = now,
        exp = cap(now + (tonumber(app.entitlement_ttl_seconds) or 900)),
        offline_until = cap(now + (tonumber(app.offline_grace_seconds) or 0)),
        policy = app.offline_policy,
    }
    local token = Signing.sign("opsapi-license+jwt", claims)
    return {
        license_file = token,
        license = { uuid = lic.uuid, status = lic.status, expires_at = tonumber(lic.expires_epoch) },
        plan = plan,
        features = ent.features,
        expires_at = claims.exp,
        offline_until = claims.offline_until,
    }
end

-- Run fn(lic, fp_hash) in a transaction after the common checks.
local function public_call(app, b, fn)
    if not Signing.configured() then
        return failure(503, "not_configured", "Licensing is not configured on this server")
    end
    local fp_hash = fingerprint_hash(b.fingerprint)
    if not fp_hash then return failure(400, "invalid_fingerprint", "fingerprint must be 8-512 characters") end
    local result, err
    local ok, tx_err = Common.transaction(function()
        local lic, ferr = usable(app, b.license_key)
        if not lic then err = ferr return true end
        result, err = fn(lic, fp_hash)
        return true
    end)
    if not ok then return failure(500, "error", tx_err or "Request failed") end
    if err then return nil, err end
    return result
end

local function info(b, field, max)
    local v = b[field]
    if type(v) ~= "string" or v == "" then return db.NULL end
    return v:sub(1, max)
end

function Licenses.activate(app, b)
    return public_call(app, b, function(lic, fp_hash)
        local live = db.query([[SELECT id FROM billing_license_activations
            WHERE license_id = ? AND fingerprint_hash = ? AND deactivated_at IS NULL]], lic.id, fp_hash)[1]
        if live then
            db.query([[UPDATE billing_license_activations SET last_seen_at = NOW(),
                name = COALESCE(?, name), platform = COALESCE(?, platform), app_version = COALESCE(?, app_version)
                WHERE id = ?]], info(b, "name", 120), info(b, "platform", 60), info(b, "app_version", 60), live.id)
        else
            local used = db.query([[SELECT count(*)::int AS n FROM billing_license_activations
                WHERE license_id = ? AND deactivated_at IS NULL]], lic.id)[1].n
            if lic.max_activations and used >= tonumber(lic.max_activations) then
                return failure(409, "activation_limit",
                    "This licence is already active on " .. used .. " device(s), its limit")
            end
            db.insert("billing_license_activations", {
                uuid = Common.uuid(), license_id = lic.id, fingerprint_hash = fp_hash,
                name = info(b, "name", 120), platform = info(b, "platform", 60),
                app_version = info(b, "app_version", 60),
            })
        end
        return license_file(app, lic, fp_hash)
    end)
end

function Licenses.validate(app, b)
    return public_call(app, b, function(lic, fp_hash)
        local res = db.query([[UPDATE billing_license_activations SET last_seen_at = NOW(),
            app_version = COALESCE(?, app_version)
            WHERE license_id = ? AND fingerprint_hash = ? AND deactivated_at IS NULL]],
            info(b, "app_version", 60), lic.id, fp_hash)
        if (res.affected_rows or 0) == 0 then
            return failure(403, "not_activated", "This device is not activated for this licence")
        end
        return license_file(app, lic, fp_hash)
    end)
end

--- Free this device's seat. Works for any non-revoked licence (an expired
-- or suspended one may still hand its seat back).
function Licenses.deactivate(app, b)
    local key = Licenses.normalize(b.license_key)
    local fp_hash = fingerprint_hash(b.fingerprint)
    if not key or not fp_hash then return failure(unpack(INVALID)) end
    local res = db.query([[UPDATE billing_license_activations x SET deactivated_at = NOW()
        FROM billing_licenses l WHERE l.id = x.license_id AND l.key_hash = ? AND l.app_id = ?
          AND x.fingerprint_hash = ? AND x.deactivated_at IS NULL]], ApiKey.hash(key), app.id, fp_hash)
    if (res.affected_rows or 0) == 0 then
        return failure(404, "not_activated", "This device is not activated for this licence")
    end
    return { deactivated = true }
end

return Licenses
